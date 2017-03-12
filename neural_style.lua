require 'torch'
require 'nn'
require 'image'
require 'optim'

require 'loadcaffe'


local cmd = torch.CmdLine()

-- Basic options
cmd:option('-style_image', 'examples/inputs/seated-nude.jpg',
           'Style target image')
cmd:option('-style_blend_weights', 'nil')
cmd:option('-content_image', 'examples/inputs/tubingen.jpg',
           'Content target image')
cmd:option('-image_size', 512, 'Maximum height / width of generated image')
cmd:option('-gpu', '0', 'Zero-indexed ID of the GPU to use; for CPU mode set -gpu = -1')
cmd:option('-multigpu_strategy', '', 'Index of layers to split the network across GPUs')

-- Optimization options
cmd:option('-content_weight', 5e0)
cmd:option('-style_weight', 1e2)
cmd:option('-tv_weight', 1e-3)
cmd:option('-num_iterations', 1000)
cmd:option('-normalize_gradients', 0.0)
cmd:option('-init', 'random', 'random|image')
cmd:option('-init_image', '')
cmd:option('-optimizer', 'lbfgs', 'lbfgs|adam')
cmd:option('-learning_rate', 1e1)
cmd:option('-lbfgs_num_correction', 0)

-- Output options
cmd:option('-print_iter', 50)
cmd:option('-save_iter', 100)
cmd:option('-output_image', 'out.png')

-- Other options
cmd:option('-style_scale', 1.0)
cmd:option('-original_colors', 0)
cmd:option('-pooling', 'max', 'max|avg')
cmd:option('-proto_file', 'models/VGG_ILSVRC_19_layers_deploy.prototxt')
cmd:option('-model_file', 'models/VGG_ILSVRC_19_layers.caffemodel')
cmd:option('-backend', 'nn', 'nn|cudnn|clnn')
cmd:option('-cudnn_autotune', false)
cmd:option('-seed', -1)

cmd:option('-padding', 'default', 'default|reflection|replication')
cmd:option('-prepadding', 0, '0|1|2|3|4|5|6|7')

cmd:option('-content_layers', 'relu4_2', 'layers for content')
cmd:option('-style_layers', 'relu1_1,relu2_1,relu3_1,relu4_1,relu5_1', 'layers for style')

local auto_off_grad_norm = true

local function main(params)
  local dtype, multigpu = setup_gpu(params)

  local loadcaffe_backend = params.backend
  if params.backend == 'clnn' then loadcaffe_backend = 'nn' end
  local cnn = loadcaffe.load(params.proto_file, params.model_file, loadcaffe_backend):type(dtype)

  local content_image = image.load(params.content_image, 3)
  content_image = image.scale(content_image, params.image_size, 'bilinear')
  local content_image_caffe = preprocess(content_image):float()

  local style_size = math.ceil(params.style_scale * params.image_size)
  local style_image_list = params.style_image:split(',')
  local style_images_caffe = {}
  for _, img_path in ipairs(style_image_list) do
    local img = image.load(img_path, 3)
    img = image.scale(img, style_size, 'bilinear')
    local img_caffe = preprocess(img):float()
    table.insert(style_images_caffe, img_caffe)
  end

  local init_image = nil
  if params.init_image ~= '' then
    init_image = image.load(params.init_image, 3)
    local H, W = content_image:size(2), content_image:size(3)
    init_image = image.scale(init_image, W, H, 'bilinear')
    init_image = preprocess(init_image):float()
  end

  -- Handle style blending weights for multiple style inputs
  local style_blend_weights = nil
  if params.style_blend_weights == 'nil' then
    -- Style blending not specified, so use equal weighting
    style_blend_weights = {}
    for i = 1, #style_image_list do
      table.insert(style_blend_weights, 1.0)
    end
  else
    style_blend_weights = params.style_blend_weights:split(',')
    assert(#style_blend_weights == #style_image_list,
      '-style_blend_weights and -style_images must have the same number of elements')
  end
  -- Normalize the style blending weights so they sum to 1
  local style_blend_sum = 0
  for i = 1, #style_blend_weights do
    style_blend_weights[i] = tonumber(style_blend_weights[i])
    style_blend_sum = style_blend_sum + style_blend_weights[i]
  end
  for i = 1, #style_blend_weights do
    style_blend_weights[i] = style_blend_weights[i] / style_blend_sum
  end

  local content_layers = params.content_layers:split(",")
  local style_layers = params.style_layers:split(",")

  -- Set up the network, inserting style and content loss modules
  local content_losses, style_losses = {}, {}
  local next_content_idx, next_style_idx = 1, 1
  local net = nn.Sequential()

  if params.prepadding == 0 then
    -- nothing
  elseif params.prepadding == 1 then                              -- nn.SpatialZeroPadding(1)
    print('Padding sequence with zeroes')
    net:add(nn.SpatialZeroPadding(1, 1, 1, 1):type(dtype))
  elseif params.prepadding == 2 then                              -- nn.SpatialReplicationPadding(1), nn.SpatialZeroPadding(1)
    print('Padding sequence with border replicas')
    net:add(nn.SpatialReplicationPadding(1, 1, 1, 1):type(dtype))
    print('Padding sequence with zeroes')
    net:add(nn.SpatialZeroPadding(1, 1, 1, 1):type(dtype))
  elseif params.prepadding == 3 then                              -- nn.SpatialReplicationPadding(2), nn.SpatialZeroPadding(1)
    print('Padding sequence with border replicas')
    net:add(nn.SpatialReplicationPadding(2, 2, 2, 2):type(dtype))
    print('Padding sequence with zeroes')
    net:add(nn.SpatialZeroPadding(1, 1, 1, 1):type(dtype))
  elseif params.prepadding == 4 then                              -- nn.SpatialReflectionPadding(2), nn.SpatialZeroPadding(1)
    print('Padding sequence with border reflections')
    net:add(nn.SpatialReflectionPadding(2, 2, 2, 2):type(dtype))
    print('Padding sequence with zeroes')
    net:add(nn.SpatialZeroPadding(1, 1, 1, 1):type(dtype))
  elseif params.prepadding == 5 then                              -- nn.SpatialReflectionPadding(2), nn.SpatialZeroPadding(1)
    print('Padding sequence with border replicas')
    net:add(nn.SpatialReplicationPadding(15, 15, 15, 15):type(dtype))
  elseif params.prepadding == 6 then                              -- nn.SpatialZeroPadding(1)
    print('Padding sequence with zeroes')
    net:add(nn.SpatialZeroPadding(15, 15, 15, 15):type(dtype))
  elseif params.prepadding == 7 then                              -- nn.SpatialZeroPadding(1)
    print('Padding sequence with zeroes')
    net:add(nn.SpatialZeroPadding(30, 30, 30, 30):type(dtype))
  end

  if params.tv_weight > 0 then
    local tv_mod = nn.TVLoss(params.tv_weight):type(dtype)
    net:add(tv_mod)
  end
  for i = 1, #cnn do
    if next_content_idx <= #content_layers or next_style_idx <= #style_layers then
      local layer = cnn:get(i)
      local name = layer.name
      local layer_type = torch.type(layer)

      local is_convolution = (layer_type == 'cudnn.SpatialConvolution' or layer_type == 'nn.SpatialConvolution')
      if is_convolution and params.padding ~= 'default' then
        local layer_padW, layer_padH = layer.padW, layer.padH
        local msg
        local pad_layer
        if params.padding == 'reflection' then
          pad_layer = nn.SpatialReflectionPadding(layer_padW, layer_padW, layer_padH, layer_padH):type(dtype)
          msg = 'Padding layer %d with reflections'
        elseif params.padding == 'replication' then
          pad_layer = nn.SpatialReplicationPadding(layer_padW, layer_padW, layer_padH, layer_padH):type(dtype)
          msg = 'Padding layer %d with edges replicas'
        else
          assert((params.padding == 'reflection' or
                  params.padding == 'replication'),
                  'Unknown padding. Stop.')
        end
        print(string.format(msg, i))
        net:add(pad_layer)
        layer.padW = 0
        layer.padH = 0
      end

      local is_pooling = (layer_type == 'cudnn.SpatialMaxPooling' or layer_type == 'nn.SpatialMaxPooling')
      if is_pooling and params.pooling == 'avg' then
        assert(layer.padW == 0 and layer.padH == 0)
        local kW, kH = layer.kW, layer.kH
        local dW, dH = layer.dW, layer.dH
        local avg_pool_layer = nn.SpatialAveragePooling(kW, kH, dW, dH):type(dtype)
        local msg = 'Replacing max pooling at layer %d with average pooling'
        print(string.format(msg, i))
        net:add(avg_pool_layer)
      else
        net:add(layer)
      end
      if name == content_layers[next_content_idx] then
        print("Setting up content layer", i, ":", layer.name)
        local norm = params.normalize_gradients
        local loss_module = nn.ContentLoss(params.content_weight, norm):type(dtype)
        net:add(loss_module)
        table.insert(content_losses, loss_module)
        next_content_idx = next_content_idx + 1
      end
      if name == style_layers[next_style_idx] then
        print("Setting up style layer  ", i, ":", layer.name)
        local norm = params.normalize_gradients
        local loss_module = nn.StyleLoss(params.style_weight, norm):type(dtype)
        net:add(loss_module)
        table.insert(style_losses, loss_module)
        next_style_idx = next_style_idx + 1
      end
    end
  end
  if multigpu then
    net = setup_multi_gpu(net, params)
  end
  net:type(dtype)

  -- Capture content targets
  for i = 1, #content_losses do
    content_losses[i].mode = 'capture'
  end
  print 'Capturing content targets'
  print(net)
  content_image_caffe = content_image_caffe:type(dtype)
  net:forward(content_image_caffe:type(dtype))

  -- Capture style targets
  for i = 1, #content_losses do
    content_losses[i].mode = 'none'
  end
  for i = 1, #style_images_caffe do
    print(string.format('Capturing style target %d', i))
    for j = 1, #style_losses do
      style_losses[j].mode = 'capture'
      style_losses[j].blend_weight = style_blend_weights[i]
    end
    net:forward(style_images_caffe[i]:type(dtype))
  end

  -- Set all loss modules to loss mode
  for i = 1, #content_losses do
    content_losses[i].mode = 'loss'
  end
  for i = 1, #style_losses do
    style_losses[i].mode = 'loss'
  end

  -- We don't need the base CNN anymore, so clean it up to save memory.
  cnn = nil
  for i=1, #net.modules do
    local module = net.modules[i]
    if torch.type(module) == 'nn.SpatialConvolutionMM' then
        -- remove these, not used, but uses gpu memory
        module.gradWeight = nil
        module.gradBias = nil
    end
  end
  collectgarbage()

  -- Initialize the image
  if params.seed >= 0 then
    torch.manualSeed(params.seed)
  end
  local img = nil
  if params.init == 'random' then
    img = torch.randn(content_image:size()):float():mul(0.001)
  elseif params.init == 'image' then
    if init_image then
      img = init_image:clone()
    else
      img = content_image_caffe:clone()
    end
  else
    error('Invalid init type')
  end
  img = img:type(dtype)

  -- Run it through the network once to get the proper size for the gradient
  -- All the gradients will come from the extra loss modules, so we just pass
  -- zeros into the top of the net on the backward pass.
  local y = net:forward(img)
  local dy = img.new(#y):zero()

  -- Declaring this here lets us access it in maybe_print
  local optim_state = nil
  if params.optimizer == 'lbfgs' then
    optim_state = {
      maxIter = params.num_iterations,
      verbose=true,
      tolX=-1,
      tolFun=-1,
    }
    if params.lbfgs_num_correction > 0 then
      optim_state.nCorrection = params.lbfgs_num_correction
    end
  elseif params.optimizer == 'adam' then
    optim_state = {
      learningRate = params.learning_rate,
    }
  else
    error(string.format('Unrecognized optimizer "%s"', params.optimizer))
  end

  local function maybe_print(t, loss)
    local verbose = (params.print_iter > 0 and t % params.print_iter == 0)
    if verbose then
      print(string.format('Iteration %d / %d', t, params.num_iterations))
      for i, loss_module in ipairs(content_losses) do
        print(string.format('  Content %d loss: %f', i, loss_module.loss))
      end
      for i, loss_module in ipairs(style_losses) do
        print(string.format('  Style %d loss: %f', i, loss_module.loss))
      end
      print(string.format('  Total loss: %f', loss))
    end
  end

  local function maybe_save(t)
    local should_save = params.save_iter > 0 and t % params.save_iter == 0
    should_save = should_save or t == params.num_iterations
    if should_save then
      local disp = deprocess(img:double())
      disp = image.minmax{tensor=disp, min=0, max=1}
      local filename = build_filename(params.output_image, t)
      if t == params.num_iterations then
        filename = params.output_image

        -- Save final result in both color variants to skip recalculation
        if params.original_colors == 2 then
          local disp_oc = original_colors(content_image, disp)
          local ext = paths.extname(filename)
          local filename_oc = string.format('%s/%s_oc.%s', paths.dirname(filename), paths.basename(filename, ext), ext)
          image.save(filename_oc, disp_oc)
        end
      end

      -- Maybe perform postprocessing for color-independent style transfer
      if params.original_colors == 1 then
        disp = original_colors(content_image, disp)
      end

      image.save(filename, disp)
    end
  end

  -- Function to evaluate loss and gradient. We run the net forward and
  -- backward to get the gradient, and sum up losses from the loss modules.
  -- optim.lbfgs internally handles iteration and calls this function many
  -- times, so we manually count the number of iterations to handle printing
  -- and saving intermediate results.
  local num_calls = 0
  local function feval(x)
    num_calls = num_calls + 1
    net:forward(x)
    local grad = net:updateGradInput(x, dy)
    local loss = 0
    local loss_content_logmean = 0
    for _, mod in ipairs(content_losses) do
      loss = loss + mod.loss
      loss_content_logmean = loss_content_logmean + math.log(mod.loss, 10)
    end
    loss_content_logmean = loss_content_logmean / #content_losses

    -- If image doesn't change, temporarily disable gradients normalization.
    local auto_off_threshold = math.log(params.content_weight, 10) - 5 + (math.log(params.style_weight, 10) / 10) 
    auto_off_grad_norm = loss_content_logmean < auto_off_threshold

    for _, mod in ipairs(style_losses) do
      loss = loss + mod.loss
    end
    maybe_print(num_calls, loss)
    maybe_save(num_calls)

    collectgarbage()
    -- optim.lbfgs expects a vector for gradients
    return loss, grad:view(grad:nElement())
  end

  -- Run optimization.
  if params.optimizer == 'lbfgs' then
    print('Running optimization with L-BFGS')
    local x, losses = optim.lbfgs(feval, img, optim_state)
  elseif params.optimizer == 'adam' then
    print('Running optimization with ADAM')
    for t = 1, params.num_iterations do
      local x, losses = optim.adam(feval, img, optim_state)
    end
  end
end


function setup_gpu(params)
  local multigpu = false
  if params.gpu:find(',') then
    multigpu = true
    params.gpu = params.gpu:split(',')
    for i = 1, #params.gpu do
      params.gpu[i] = tonumber(params.gpu[i]) + 1
    end
  else
    params.gpu = tonumber(params.gpu) + 1
  end
  local dtype = 'torch.FloatTensor'
  if multigpu or params.gpu > 0 then
    if params.backend ~= 'clnn' then
      require 'cutorch'
      require 'cunn'
      if multigpu then
        cutorch.setDevice(params.gpu[1])
      else
        cutorch.setDevice(params.gpu)
      end
      dtype = 'torch.CudaTensor'
    else
      require 'clnn'
      require 'cltorch'
      if multigpu then
        cltorch.setDevice(params.gpu[1])
      else
        cltorch.setDevice(params.gpu)
      end
      dtype = torch.Tensor():cl():type()
    end
  else
    params.backend = 'nn'
  end

  if params.backend == 'cudnn' then
    require 'cudnn'
    if params.cudnn_autotune then
      cudnn.benchmark = true
    end
    cudnn.SpatialConvolution.accGradParameters = nn.SpatialConvolutionMM.accGradParameters -- ie: nop
  end
  return dtype, multigpu
end


function setup_multi_gpu(net, params)
  local DEFAULT_STRATEGIES = {
    [2] = {3},
  }
  local gpu_splits = nil
  if params.multigpu_strategy == '' then
    -- Use a default strategy
    gpu_splits = DEFAULT_STRATEGIES[#params.gpu]
    -- Offset the default strategy by one if we are using TV
    if params.tv_weight > 0 then
      for i = 1, #gpu_splits do gpu_splits[i] = gpu_splits[i] + 1 end
    end
  else
    -- Use the user-specified multigpu strategy
    gpu_splits = params.multigpu_strategy:split(',')
    for i = 1, #gpu_splits do
      gpu_splits[i] = tonumber(gpu_splits[i])
    end
  end
  assert(gpu_splits ~= nil, 'Must specify -multigpu_strategy')
  local gpus = params.gpu

  local cur_chunk = nn.Sequential()
  local chunks = {}
  for i = 1, #net do
    cur_chunk:add(net:get(i))
    if i == gpu_splits[1] then
      table.remove(gpu_splits, 1)
      table.insert(chunks, cur_chunk)
      cur_chunk = nn.Sequential()
    end
  end
  table.insert(chunks, cur_chunk)
  assert(#chunks == #gpus)

  local new_net = nn.Sequential()
  for i = 1, #chunks do
    local out_device = nil
    if i == #chunks then
      out_device = gpus[1]
    end
    new_net:add(nn.GPU(chunks[i], gpus[i], out_device))
  end

  return new_net
end


function build_filename(output_image, iteration)
  local ext = paths.extname(output_image)
  local basename = paths.basename(output_image, ext)
  local directory = paths.dirname(output_image)
  return string.format('%s/%s_%d.%s',directory, basename, iteration, ext)
end


-- Preprocess an image before passing it to a Caffe model.
-- We need to rescale from [0, 1] to [0, 255], convert from RGB to BGR,
-- and subtract the mean pixel.
function preprocess(img)
  local mean_pixel = torch.DoubleTensor({103.939, 116.779, 123.68})
  local perm = torch.LongTensor{3, 2, 1}
  local img_p = torch.mul(img:index(1, perm), 256.0)
  mean_pixel = mean_pixel:view(3, 1, 1):expandAs(img)
  img_p:add(-1, mean_pixel)
  return img_p
end


-- Undo the above preprocessing.
function deprocess(img)
  local mean_pixel = torch.DoubleTensor({103.939, 116.779, 123.68})
  mean_pixel = mean_pixel:view(3, 1, 1):expandAs(img)
  local img_d = img + mean_pixel
  local perm = torch.LongTensor{3, 2, 1}
  img_d = img_d:index(1, perm):div(256.0)
  return img_d
end


-- Combine the Y channel of the generated image and the UV channels of the
-- content image to perform color-independent style transfer.
function original_colors(content, generated)
  local generated_y = image.rgb2yuv(generated)[{{1, 1}}]
  local content_uv = image.rgb2yuv(content)[{{2, 3}}]
  return image.yuv2rgb(torch.cat(generated_y, content_uv, 1))
end


-- from Leon Gatys's code: https://github.com/leongatys/NeuralImageSynthesis/blob/master/ExampleNotebooks/ColourControl.ipynb
-- and ProGamerGov's code: https://github.com/jcjohnson/neural-style/issues/376
function match_color(target_img, source_img, mode, eps)
  mode = mode or 'pca'
  eps = eps or 1e-5

  if mode == 'lab' then
    -- Color transfer between images
    -- https://github.com/jrosebr1/color_transfer
    -- https://www.researchgate.net/publication/220518215_Color_Transfer_between_Images
    -- https://www.cs.tau.ac.il/~turkel/imagepapers/ColorTransfer.pdf
    local s_lab = image.rgb2lab(source_img)  -- -100...100 range?
    local t_lab = image.rgb2lab(target_img)
    -- print(s_lab:min(), s_lab:max())
    -- print(t_lab:min(), t_lab:max())
    local sMean, sStd = s_lab:mean(3):mean(2), s_lab:view(s_lab:size(1), s_lab[1]:nElement()):std(2):view(3,1,1)
    local tMean, tStd = t_lab:mean(3):mean(2), t_lab:view(t_lab:size(1), t_lab[1]:nElement()):std(2):view(3,1,1)
    local tCol = (t_lab - tMean:expandAs(t_lab)):cmul(sStd:expandAs(t_lab)):cdiv(tStd:expandAs(t_lab)) + sMean:expandAs(t_lab)
    return image.lab2rgb(tCol:clamp(0, 255)):clamp(0, 1)
  elseif mode == 'rgb' then
    local sMean, sStd = source_img:mean(3):mean(2), source_img:view(source_img:size(1), source_img[1]:nElement()):std(2):view(3,1,1)
    local tMean, tStd = target_img:mean(3):mean(2), target_img:view(target_img:size(1), target_img[1]:nElement()):std(2):view(3,1,1)
    local tCol = (target_img - tMean:expandAs(target_img)):cmul(sStd:expandAs(target_img)):cdiv(tStd:expandAs(target_img)) + sMean:expandAs(target_img)
    return tCol:clamp(0, 1)
  elseif mode == 'xyz' then
    -- Coefficients from https://github.com/THEjoezack/ColorMine/blob/master/ColorMine/ColorSpaces/Conversions/XyzConverter.cs
    -- X = r * 0.4124 + g * 0.3576 + b * 0.1805;
    -- Y = r * 0.2126 + g * 0.7152 + b * 0.0722;
    -- Z = r * 0.0193 + g * 0.1192 + b * 0.9505;

    -- r = x *  3.2406 + y * -1.5372 + z * -0.4986;
    -- g = x * -0.9689 + y *  1.8758 + z *  0.0415;
    -- b = x *  0.0557 + y * -0.2040 + z *  1.0570;

    -- local xyz_s = torch.Tensor(source_img:size(1),source_img:size(2),source_img:size(3))
    -- xyz_s[1] = torch.mul(source_img[1], 0.4124) + torch.mul(source_img[2], 0.3576) + torch.mul(source_img[3], 0.1805)
    -- xyz_s[2] = torch.mul(source_img[1], 0.2126) + torch.mul(source_img[2], 0.7152) + torch.mul(source_img[3], 0.0722)
    -- xyz_s[3] = torch.mul(source_img[1], 0.0193) + torch.mul(source_img[2], 0.1192) + torch.mul(source_img[3], 0.9505)

    local rgb_xyz_mat = torch.Tensor({{0.4124, 0.3576, 0.1805},
                                      {0.2126, 0.7152, 0.0722},
                                      {0.0193, 0.1192, 0.9505}})
    local xyz_s = (rgb_xyz_mat * source_img:view(source_img:size(1), source_img[1]:nElement()))
    local xyz_t = (rgb_xyz_mat * target_img:view(target_img:size(1), target_img[1]:nElement()))

    local sMean, sStd = torch.mean(xyz_s, 2), torch.std(xyz_s, 2)
    local tMean, tStd = torch.mean(xyz_t, 2), torch.std(xyz_t, 2)
    local tCol = (xyz_t - tMean:expandAs(xyz_t)):cmul(sStd:expandAs(xyz_t)):cdiv(tStd:expandAs(xyz_t)) + sMean:expandAs(xyz_t)

    local xyz_rgb_mat = torch.Tensor({{ 3.2406, -1.5372, -0.4986},
                                      {-0.9689,  1.8758,  0.0415},
                                      { 0.0557, -0.2040,  1.0570}})
    tCol = (xyz_rgb_mat * tCol):viewAs(target_img)
    return tCol:clamp(0, 1)
  elseif mode == 'lms' then
    -- https://www.researchgate.net/publication/220518215_Color_Transfer_between_Images
    -- https://www.cs.tau.ac.il/~turkel/imagepapers/ColorTransfer.pdf

    --   r       g       b
    -- l 0.3811  0.5783  0.0402
    -- m 0.1967  0.7244  0.0782
    -- s 0.0241  0.1288  0.8444
    -- l,m,s = log(l,m,s)  -- Decimal logarithm is used in original paper, but
                           -- it seems that function can be done with natural logarithms, and
                           -- without division/multiplication by log(10) it should be a little faster.

    -- l   m   s
    -- 1,  1,  1
    -- 1,  1, -2
    -- 1, -1,  0

    -- l 1/sqr(3), 0, 0
    -- a 0, 1/sqr(6), 0
    -- b 0, 0, 1/sqr(2)

    -- Lab = (t - Mean(t)) * Std(s) / Std(t) + Mean(s)

    -- l         a         b
    -- sqr(3)/3, 0,        0
    -- 0,        sqr(6)/6, 0
    -- 0,        0,        sqr(2)/2

    -- l 1, 1, 1
    -- m 1, 1, -1
    -- s 1, -2, 0

    -- l,m,s = 10^{l,m,s}   -- e^{l,m,s} ?
    --   l       m        s
    -- r  4.4679 -3.5873  0.1193
    -- g -1.2186  2.3809 -0.1624
    -- b  0.0497 -0.2439  1.2045

    local rgb_lms_mat = torch.Tensor({{0.3811, 0.5783, 0.0402},
                                      {0.1967, 0.7244, 0.0782},
                                      {0.0241, 0.1288, 0.8444}})
    local lms_mat2 = torch.Tensor({{1.0,  1.0,  1.0},
                                   {1.0,  1.0, -2.0},
                                   {1.0, -1.0,  0.0}})
    local lms_mat3 = torch.Tensor({{1/math.sqrt(3), 0.0,            0.0},
                                   {0.0,            1/math.sqrt(6), 0.0},
                                   {0.0,            0.0,            1/math.sqrt(2)}})

    local lms_s = (rgb_lms_mat * source_img:view(source_img:size(1), source_img[1]:nElement()))
    local lms_s_l = torch.log(lms_s + eps) -- / math.log(10)
    lms_s_l = lms_mat2 * lms_s_l
    lms_s_l = lms_mat3 * lms_s_l

    local lms_t = (rgb_lms_mat * target_img:view(target_img:size(1), target_img[1]:nElement()))
    local lms_t_l = torch.log(lms_t + eps) -- / math.log(10)
    lms_t_l = lms_mat2 * lms_t_l
    lms_t_l = lms_mat3 * lms_t_l

    local sMean, sStd = torch.mean(lms_s_l, 2), torch.std(lms_s_l, 2)
    local tMean, tStd = torch.mean(lms_t_l, 2), torch.std(lms_t_l, 2)
    local tCol = (lms_t_l - tMean:expandAs(lms_t_l)):cmul(sStd:expandAs(lms_t_l)):cdiv(tStd:expandAs(lms_t_l)) + sMean:expandAs(lms_t_l)

    local lms_mat4 = torch.Tensor({{math.sqrt(3)/3, 0.0,            0.0},
                                   {0.0,            math.sqrt(6)/6, 0.0},
                                   {0.0,            0.0,            math.sqrt(2)/2}})
    local lms_mat5 = torch.Tensor({{1.0,  1.0,  1.0},
                                   {1.0,  1.0, -1.0},
                                   {1.0, -2.0,  0.0}})
    local lms_rgb_mat = torch.Tensor({{ 4.4679, -3.5873,  0.1193},
                                      {-1.2186,  2.3809, -0.1624},
                                      { 0.0497, -0.2439,  1.2045}})
    tCol = lms_mat4 * tCol
    tCol = lms_mat5 * tCol
    tCol = torch.exp(tCol)  -- decimal: tCol = torch.exp(tCol * math.log(10)) --??? - 1e-5
    local lms_rgb = (lms_rgb_mat * tCol):viewAs(target_img)
    return lms_rgb:clamp(0, 1)
  elseif mode == 'hsl' then
    local s_hsl = image.rgb2hsl(source_img)  -- 0...1 range?
    local t_hsl = image.rgb2hsl(target_img)
    local sMean, sStd = s_hsl:mean(3):mean(2), s_hsl:view(s_hsl:size(1), s_hsl[1]:nElement()):var(2):view(3,1,1)
    local tMean, tStd = t_hsl:mean(3):mean(2), t_hsl:view(t_hsl:size(1), t_hsl[1]:nElement()):var(2):view(3,1,1)
    local tCol = (t_hsl - tMean:expandAs(t_hsl)):cmul(sStd:expandAs(t_hsl)):cdiv(tStd:expandAs(t_hsl)) + sMean:expandAs(t_hsl)
    tCol[2]:clamp(0, 1)
    tCol[2] = image.minmax{tensor = tCol[2], min = 0, max = 1}
    return image.hsl2rgb(tCol):clamp(0, 1)
  end

  -- Matches the colour distribution of the target image to that of the source image
  -- using a linear transform.
  -- Images are expected to be of form (c,h,w) and float in [0,1].
  -- Modes are chol, pca or sym for different choices of basis.

  local eyem = torch.eye(source_img:size(1)):mul(eps)

  local mu_s = torch.mean(source_img, 3):mean(2)
  local s = source_img - mu_s:expandAs(source_img)
  s = s:view(s:size(1), s[1]:nElement())
  local Cs = s * s:t() / s:size(2) + eyem

  local mu_t = torch.mean(target_img, 3):mean(2)
  local t = target_img - mu_t:expandAs(target_img)
  t = t:view(t:size(1), t[1]:nElement())
  local Ct = t * t:t() / t:size(2) + eyem

  local ts
  if mode == 'chol' then
    local chol_s = torch.potrf(Cs, 'L')
    local chol_t = torch.potrf(Ct, 'L')
    ts = chol_s * torch.inverse(chol_t) * t
  elseif mode == 'pca' then
    local eva_t, eve_t = torch.symeig(Ct, 'V', 'L')
    local Qt = eve_t * torch.diag(eva_t):sqrt() * eve_t:t()
    local eva_s, eve_s = torch.symeig(Cs, 'V', 'L')
    local Qs = eve_s * torch.diag(eva_s):sqrt() * eve_s:t()
    ts = Qs * torch.inverse(Qt) * t
  elseif mode == 'sym' then
    local eva_t, eve_t = torch.symeig(Ct, 'V', 'L')
    local Qt = eve_t * torch.diag(eva_t):sqrt() * eve_t:t()
    local Qt_Cs_Qt = Qt * Cs * Qt
    local eva_QtCsQt, eve_QtCsQt = torch.symeig(Qt_Cs_Qt, 'V', 'L')
    local QtCsQt = eve_QtCsQt * torch.diag(eva_QtCsQt):sqrt() * eve_QtCsQt:t()
    local iQt = torch.inverse(Qt)
    ts = iQt * QtCsQt * iQt * t
  else
    error('Unknown color matching mode. Stop.')
  end

  local matched_img = ts:viewAs(target_img) + mu_s:expandAs(target_img)
  -- matched_img = image.minmax{tensor=matched_img, min=0, max=1}
  return matched_img:clamp(0, 1)
end


-- Define an nn Module to compute content loss in-place
local ContentLoss, parent = torch.class('nn.ContentLoss', 'nn.Module')

function ContentLoss:__init(strength, normalize)
  parent.__init(self)
  self.strength = strength
  self.target = torch.Tensor()
  self.normalize = normalize
  if self.normalize > 1.0 then self.normalize = 1.0 end
  self.loss = 0
  self.crit = nn.MSECriterion()
  self.mode = 'none'
end

function ContentLoss:updateOutput(input)
  if self.mode == 'loss' then
    self.loss = self.crit:forward(input, self.target) * self.strength
  elseif self.mode == 'capture' then
    self.target:resizeAs(input):copy(input)
  end
  self.output = input
  return self.output
end

function ContentLoss:updateGradInput(input, gradOutput)
  if self.mode == 'loss' then
    if input:nElement() == self.target:nElement() then
      self.gradInput = self.crit:backward(input, self.target)
    end
    if (self.normalize ~= 0.0) and (auto_off_grad_norm == false) then
      if self.normalize == 1.0 then
        self.gradInput:div(torch.norm(self.gradInput, 1) + 1e-8)
      else
        self.gradInput:div(torch.norm(self.gradInput, 1) ^ self.normalize + 1e-8)
      end
    end
    self.gradInput:mul(self.strength)
    self.gradInput:add(gradOutput)
  else
    self.gradInput:resizeAs(gradOutput):copy(gradOutput)
  end
  return self.gradInput
end


local Gram, parent = torch.class('nn.GramMatrix', 'nn.Module')

function Gram:__init()
  parent.__init(self)
end

function Gram:updateOutput(input)
  assert(input:dim() == 3)
  local C, H, W = input:size(1), input:size(2), input:size(3)
  local x_flat = input:view(C, H * W)
  self.output:resize(C, C)
  self.output:mm(x_flat, x_flat:t())
  return self.output
end

function Gram:updateGradInput(input, gradOutput)
  assert(input:dim() == 3 and input:size(1))
  local C, H, W = input:size(1), input:size(2), input:size(3)
  local x_flat = input:view(C, H * W)
  self.gradInput:resize(C, H * W):mm(gradOutput, x_flat)
  self.gradInput:addmm(gradOutput:t(), x_flat)
  self.gradInput = self.gradInput:view(C, H, W)
  return self.gradInput
end


-- Define an nn Module to compute style loss in-place
local StyleLoss, parent = torch.class('nn.StyleLoss', 'nn.Module')

function StyleLoss:__init(strength, normalize)
  parent.__init(self)
  self.normalize = normalize
  if self.normalize > 1.0 then self.normalize = 1.0 end
  self.strength = strength
  self.target = torch.Tensor()
  self.mode = 'none'
  self.loss = 0

  self.gram = nn.GramMatrix()
  self.blend_weight = nil
  self.G = nil
  self.crit = nn.MSECriterion()
end

function StyleLoss:updateOutput(input)
  self.G = self.gram:forward(input)
  self.G:div(input:nElement())
  if self.mode == 'capture' then
    if self.blend_weight == nil then
      self.target:resizeAs(self.G):copy(self.G)
    elseif self.target:nElement() == 0 then
      self.target:resizeAs(self.G):copy(self.G):mul(self.blend_weight)
    else
      self.target:add(self.blend_weight, self.G)
    end
  elseif self.mode == 'loss' then
    self.loss = self.strength * self.crit:forward(self.G, self.target)
  end
  self.output = input
  return self.output
end

function StyleLoss:updateGradInput(input, gradOutput)
  if self.mode == 'loss' then
    local dG = self.crit:backward(self.G, self.target)
    dG:div(input:nElement())
    self.gradInput = self.gram:backward(input, dG)
    if (self.normalize ~= 0.0) and (auto_off_grad_norm == false) then
      if self.normalize == 1.0 then
        self.gradInput:div(torch.norm(self.gradInput, 1) + 1e-8)
      else
        self.gradInput:div(torch.norm(self.gradInput, 1) ^ self.normalize + 1e-8)
      end
    end
    self.gradInput:mul(self.strength)
    self.gradInput:add(gradOutput)
  else
    self.gradInput = gradOutput
  end
  return self.gradInput
end


local TVLoss, parent = torch.class('nn.TVLoss', 'nn.Module')

function TVLoss:__init(strength)
  parent.__init(self)
  self.strength = strength
  self.x_diff = torch.Tensor()
  self.y_diff = torch.Tensor()
end

function TVLoss:updateOutput(input)
  self.output = input
  return self.output
end

-- TV loss backward pass inspired by kaishengtai/neuralart
function TVLoss:updateGradInput(input, gradOutput)
  self.gradInput:resizeAs(input):zero()
  local C, H, W = input:size(1), input:size(2), input:size(3)
  self.x_diff:resize(3, H - 1, W - 1)
  self.y_diff:resize(3, H - 1, W - 1)
  self.x_diff:copy(input[{{}, {1, -2}, {1, -2}}])
  self.x_diff:add(-1, input[{{}, {1, -2}, {2, -1}}])
  self.y_diff:copy(input[{{}, {1, -2}, {1, -2}}])
  self.y_diff:add(-1, input[{{}, {2, -1}, {1, -2}}])
  self.gradInput[{{}, {1, -2}, {1, -2}}]:add(self.x_diff):add(self.y_diff)
  self.gradInput[{{}, {1, -2}, {2, -1}}]:add(-1, self.x_diff)
  self.gradInput[{{}, {2, -1}, {1, -2}}]:add(-1, self.y_diff)
  self.gradInput:mul(self.strength)
  self.gradInput:add(gradOutput)
  return self.gradInput
end


local params = cmd:parse(arg)
main(params)
