local Constants = {}

Constants.WORLD_SIZE_X = 256
Constants.WORLD_SIZE_Z = 256
Constants.WORLD_SIZE_Y = 64
Constants.CHUNK_SIZE = 16
Constants.CHUNK_VOLUME = Constants.CHUNK_SIZE * Constants.CHUNK_SIZE * Constants.CHUNK_SIZE
Constants.WORLD_CHUNKS_X = math.ceil(Constants.WORLD_SIZE_X / Constants.CHUNK_SIZE)
Constants.WORLD_CHUNKS_Y = math.ceil(Constants.WORLD_SIZE_Y / Constants.CHUNK_SIZE)
Constants.WORLD_CHUNKS_Z = math.ceil(Constants.WORLD_SIZE_Z / Constants.CHUNK_SIZE)

Constants.WORLD_SEED = 1337
Constants.TREE_DENSITY = 0.0175

Constants.DAY_LENGTH_SECONDS = 300

Constants.SKY_DAY = { .53, .78, .96 }
Constants.SKY_NIGHT = { .03, .04, .09 }

Constants.CULL = {
  enabled = true,
  drawRadiusChunks = 4,
  fovDegrees = 110,
  fovPaddingDegrees = 8,
  horizontalOnly = true,
  alwaysVisiblePaddingChunks = 1
}

Constants.MESH = {
  greedy = true
}

Constants.REBUILD = {
  maxPerFrame = 3,
  -- Prevents a huge startup hitch when the world has many chunks.
  initialBurstMax = 700,
  prioritize = true,
  prioritizeHorizontalOnly = true
}

Constants.PERF = {
  showHud = true,
  hudUpdateInterval = 0.10
}

Constants.SAVE = {
  enabled = true,
  autosaveIntervalSeconds = 60,
  autosaveShowHudSeconds = 1.5
}

Constants.BLOCK = {
  AIR = 0,
  GRASS = 1,
  DIRT = 2,
  STONE = 3,
  BEDROCK = 4,
  WOOD = 5,
  LEAF = 6
}

Constants.BLOCK_INFO = {
  [Constants.BLOCK.AIR] = {
    name = 'Air',
    color = { 0, 0, 0 },
    solid = false,
    opaque = false,
    breakable = false,
    placeable = false,
    alpha = 0
  },
  [Constants.BLOCK.GRASS] = {
    name = 'Grass',
    color = { .35, .72, .28 },
    solid = true,
    opaque = true,
    breakable = true,
    placeable = true,
    alpha = 1
  },
  [Constants.BLOCK.DIRT] = {
    name = 'Dirt',
    color = { .47, .34, .20 },
    solid = true,
    opaque = true,
    breakable = true,
    placeable = true,
    alpha = 1
  },
  [Constants.BLOCK.STONE] = {
    name = 'Stone',
    color = { .52, .53, .56 },
    solid = true,
    opaque = true,
    breakable = true,
    placeable = true,
    alpha = 1
  },
  [Constants.BLOCK.BEDROCK] = {
    name = 'Bedrock',
    color = { .18, .18, .20 },
    solid = true,
    opaque = true,
    breakable = false,
    placeable = false,
    alpha = 1
  },
  [Constants.BLOCK.WOOD] = {
    name = 'Wood',
    color = { .58, .42, .24 },
    solid = true,
    opaque = true,
    breakable = true,
    placeable = true,
    alpha = 1
  },
  [Constants.BLOCK.LEAF] = {
    name = 'Leaf',
    color = { .23, .55, .24 },
    solid = true,
    opaque = false,
    breakable = true,
    placeable = true,
    alpha = .92
  }
}

Constants.INVENTORY_SLOT_COUNT = 8
Constants.INVENTORY_START_COUNT = 48
Constants.HOTBAR_DEFAULTS = {
  Constants.BLOCK.GRASS,
  Constants.BLOCK.DIRT,
  Constants.BLOCK.STONE,
  Constants.BLOCK.WOOD,
  Constants.BLOCK.LEAF
}

Constants.PLAYER = {
  radius = .30,
  height = 1.80,
  eyeHeight = 1.62,
  speed = 6.0,
  gravity = 22.0,
  jumpSpeed = 8.0,
  reach = 6.0,
  lookSensitivity = 0.0028
}

return Constants
