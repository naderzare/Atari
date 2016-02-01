local _ = require 'moses'
local classic = require 'classic'
local nn = require 'nn'
local image = require 'image'
local DuelAggregator = require 'modules/DuelAggregator'
require 'classic.torch' -- Enables serialisation
require 'dpnn' -- Adds gradParamClip method
require 'modules/GuidedReLU'
require 'modules/DeconvnetReLU'
require 'modules/GradientRescale'

local Model = classic.class('Model')

-- Creates a Model (a helper for the network it creates)
function Model:_init(opt)
  -- Extract relevant options
  self.gpu = opt.gpu
  self.colorSpace = opt.colorSpace
  self.width = opt.width
  self.height = opt.height
  self.nChannels = opt.nChannels
  self.histLen = opt.histLen
  self.duel = opt.duel
  self.ale = opt.ale

  -- Get cuDNN if available
  self.hasCudnn = pcall(require, 'cudnn')
end

-- Processes a single frame for DQN input
function Model:preprocess(observation)
  if self.ale then
    -- Load frame
    local frame = observation:select(1, 1):float() -- Convert from CudaTensor if necessary
    -- Perform colour conversion
    if self.colorSpace ~= 'rgb' then
      frame = image['rgb2' .. self.colorSpace](frame)
    end

    -- Resize 210x160 screen
    return image.scale(frame, self.width, self.height)
  else
    -- Return normal Catch screen
    return observation
  end
end

-- Creates a dueling DQN based on a number of discrete actions
function Model:create(m)
  -- Size of fully connected layers
  local hiddenSize = self.ale and 512 or 32

  -- Network starting with convolutional layers
  local net = nn.Sequential()
  net:add(nn.View(self.histLen*self.nChannels, self.height, self.width)) -- Concatenate history in channel dimension
  if self.ale then
    net:add(nn.SpatialConvolution(self.histLen*self.nChannels, 32, 8, 8, 4, 4))
    net:add(nn.ReLU(true))
    net:add(nn.SpatialConvolution(32, 64, 4, 4, 2, 2))
    net:add(nn.ReLU(true))
    net:add(nn.SpatialConvolution(64, 64, 3, 3, 1, 1))
    net:add(nn.ReLU(true))
  else
    net:add(nn.SpatialConvolution(self.histLen*self.nChannels, 32, 5, 5, 2, 2))
    net:add(nn.ReLU(true))
    net:add(nn.SpatialConvolution(32, 64, 3, 3, 1, 1))
    net:add(nn.ReLU(true))
  end
  -- Calculate convolutional network output size
  local convOutputSize = torch.prod(torch.Tensor(net:forward(torch.Tensor(torch.LongStorage({self.histLen*self.nChannels, self.height, self.width}))):size():totable()))
  net:add(nn.View(convOutputSize))

  if self.duel then
    -- Value approximator V^(s)
    local valStream = nn.Sequential()
    valStream:add(nn.Linear(convOutputSize, hiddenSize))
    valStream:add(nn.ReLU(true))
    valStream:add(nn.Linear(hiddenSize, 1)) -- Predicts value for state

    -- Advantage approximator A^(s, a)
    local advStream = nn.Sequential()
    advStream:add(nn.Linear(convOutputSize, hiddenSize))
    advStream:add(nn.ReLU(true))
    advStream:add(nn.Linear(hiddenSize, m)) -- Predicts action-conditional advantage

    -- Streams container
    local streams = nn.ConcatTable()
    streams:add(valStream)
    streams:add(advStream)
    
    -- Network finishing with fully connected layers
    net:add(nn.GradientRescale(1 / math.sqrt(2), true)) -- Heuristic that mildly increases stability for duel
    -- Create dueling streams
    net:add(streams)
    -- Add dueling streams aggregator module
    net:add(DuelAggregator(m))
  else
    net:add(nn.Linear(convOutputSize, hiddenSize))
    net:add(nn.ReLU(true))
    net:add(nn.Linear(hiddenSize, m))
  end
  -- TODO: Check need for shared bias at last layer (as used in tuned DDQN)

  -- GPU conversion
  if self.gpu > 0 then
    require 'cunn'
    if self.hasCudnn then
      cudnn.convert(net, cudnn)
    end
    net:cuda()
  end

  -- Save reference to network
  self.net = net

  return net
end

-- Set ReLUs up for specified saliency visualisation type
function Model:setSaliency(saliency)
  -- Set saliency
  self.saliency = saliency

  -- nn vs. cuDNN backend
  --local backend = (self.gpu > 0 and self.hasCudnn) and 'cudnn' or 'nn'
  -- Find ReLUs on existing model
  local relus, relucontainers = self.net:findModules('nn.ReLU')
  if #relus == 0 then
    relus, relucontainers = self.net:findModules('cudnn.ReLU')
  end
  if #relus == 0 then
    relus, relucontainers = self.net:findModules('nn.GuidedReLU')
  end
  if #relus == 0 then
    relus, relucontainers = self.net:findModules('nn.DeconvnetReLU')
  end

  -- Work out which ReLU to use now
  local layerConstructor = (self.gpu > 0 and self.hasCudnn) and cudnn.ReLU or nn.ReLU
  self.relus = {} --- Clear special ReLU list to iterate over for salient backpropagation
  if saliency == 'guided' then
    layerConstructor = nn.GuidedReLU
  elseif saliency == 'deconvnet' then
    layerConstructor = nn.DeconvnetReLU
  end

  -- Replace ReLUs
  for i = 1, #relus do
    -- Create new special ReLU
    local layer = layerConstructor()

    -- Copy everything over
    for key, val in pairs(relus[i]) do
      layer[key] = val
    end

    -- Find ReLU in containing module and replace
    for j = 1, #(relucontainers[i].modules) do
      if relucontainers[i].modules[j] == relus[i] then
        relucontainers[i].modules[j] = layer
      end
    end
  end

  -- Create special ReLU list to iterate over for salient backpropagation
  self.relus = self.net:findModules(saliency == 'guided' and 'nn.GuidedReLU' or 'nn.DeconvnetReLU')
end

-- Switches the backward computation of special ReLUs for salient backpropagation
function Model:salientBackprop()
  for i, v in ipairs(self.relus) do
    v:salientBackprop()
  end
end

-- Switches the backward computation of special ReLUs for normal backpropagation
function Model:normalBackprop()
  for i, v in ipairs(self.relus) do
    v:normalBackprop()
  end
end

return Model