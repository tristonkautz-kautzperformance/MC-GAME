local Constants = {}

Constants.WORLD_SIZE_X = 1280
Constants.WORLD_SIZE_Z = 1280
Constants.WORLD_SIZE_Y = 64
Constants.CHUNK_SIZE = 16
Constants.CHUNK_VOLUME = Constants.CHUNK_SIZE * Constants.CHUNK_SIZE * Constants.CHUNK_SIZE
Constants.WORLD_CHUNKS_X = math.ceil(Constants.WORLD_SIZE_X / Constants.CHUNK_SIZE)
Constants.WORLD_CHUNKS_Y = math.ceil(Constants.WORLD_SIZE_Y / Constants.CHUNK_SIZE)
Constants.WORLD_CHUNKS_Z = math.ceil(Constants.WORLD_SIZE_Z / Constants.CHUNK_SIZE)

Constants.WORLD_SEED = 1337
Constants.TREE_DENSITY = 0.014

-- World-gen tuning.
-- Heights are world Y block indices in [1..WORLD_SIZE_Y].
Constants.GEN = {
  seaLevel = 20,
  baseHeight = 22,
  terrainAmplitude = 11,
  detailFrequency = 0.018,
  detailOctaves = 4,
  detailPersistence = 0.5,
  continentFrequency = 0.0035,
  continentAmplitude = 8,
  beachBand = 2,
  dirtMinDepth = 2,
  dirtMaxDepth = 4,
  sandMinDepth = 2,
  sandMaxDepth = 4,
  treeTrunkMin = 3,
  treeTrunkMax = 5,
  treeLeafPad = 2,
  treeWaterBuffer = 1
}

Constants.DAY_LENGTH_SECONDS = 300

Constants.SKY_DAY = { .53, .78, .96 }
Constants.SKY_NIGHT = { .03, .04, .09 }

Constants.LIGHTING = {
  enabled = true,
  mode = 'floodfill',
  leafOpacity = 4,
  maxUpdatesPerFrame = 8192,
  maxMillisPerFrame = 1.25,
  regionStripOpsPerFrame = 1024,
  regionStripMillisPerFrame = 0.35,
  urgentOpsPerFrame = 12288,
  urgentMillisPerFrame = 1.75,
  chunkEnsureOps = 768,
  chunkEnsureMillis = 0.2,
  chunkEnsureSpikeSoftMs = 12,
  chunkEnsureSpikeHardMs = 20,
  chunkEnsureSpikeSoftScale = 0.5,
  chunkEnsureSpikeHardScale = 0.2,
  startupWarmupOpsPerFrame = 32768,
  startupWarmupMillisPerFrame = 4.0,
  editRelightRadiusBlocks = 15,
  editImmediateOps = 8192,
  editImmediateMillis = 0,
  floodfillExtraKeepRadiusChunks = 1,
  debugDraw = false,
  debugForceGrayscale = false
}

Constants.CULL = {
  enabled = true,
  drawRadiusChunks = 4,
  fovDegrees = 110,
  fovPaddingDegrees = 8,
  horizontalOnly = true,
  alwaysVisiblePaddingChunks = 1,
  meshCachePaddingChunks = 2
}

Constants.MESH = {
  greedy = true,
  indexed = false
}

Constants.RENDER = {
  cullOpaque = true,
  cullAlpha = false
}

Constants.THREAD_MESH = {
  enabled = true,
  haloBlob = true,
  resultBlob = true,
  maxInFlight = 2,
  maxApplyMillis = 1.0
}

Constants.REBUILD = {
  maxPerFrame = 24,
  maxMillisPerFrame = 2.5,
  -- Releasing many meshes during movement can stall on some drivers.
  -- Keep runtime releases off by default; meshes are still released on shutdown.
  releaseMeshesRuntime = false,
  -- Prevents a huge startup hitch when the world has many chunks.
  initialBurstMax = 700,
  initialBurstMaxMillis = 12.0,
  prioritize = true,
  prioritizeHorizontalOnly = true,
  -- Only perform full O(queue) rebucket when backlog is small.
  rebucketFullThreshold = 128,
  -- Max stale entries requeued per rebuild call before forcing progress.
  staleRequeueCap = 32,
  -- Incremental mesh-cache pruning budget to avoid chunk-crossing spikes.
  pruneMaxChecksPerFrame = 128,
  pruneMaxMillisPerFrame = 0.25
}

Constants.PERF = {
  showHud = true,
  hudUpdateInterval = 0.10,
  enqueuedShowSeconds = 0.5
}

Constants.SAVE = {
  enabled = false,
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
  LEAF = 6,
  SAND = 7,
  WATER = 8
}

Constants.ITEM = {
  SWORD = 1001
}

Constants.BLOCK_INFO = {
  [Constants.BLOCK.AIR] = {
    name = 'Air',
    color = { 0, 0, 0 },
    solid = false,
    opaque = false,
    lightOpacity = 0,
    breakable = false,
    placeable = false,
    alpha = 0
  },
  [Constants.BLOCK.GRASS] = {
    name = 'Grass',
    color = { .35, .72, .28 },
    solid = true,
    opaque = true,
    lightOpacity = 15,
    breakable = true,
    placeable = true,
    alpha = 1
  },
  [Constants.BLOCK.DIRT] = {
    name = 'Dirt',
    color = { .47, .34, .20 },
    solid = true,
    opaque = true,
    lightOpacity = 15,
    breakable = true,
    placeable = true,
    alpha = 1
  },
  [Constants.BLOCK.STONE] = {
    name = 'Stone',
    color = { .52, .53, .56 },
    solid = true,
    opaque = true,
    lightOpacity = 15,
    breakable = true,
    placeable = true,
    alpha = 1
  },
  [Constants.BLOCK.BEDROCK] = {
    name = 'Bedrock',
    color = { .18, .18, .20 },
    solid = true,
    opaque = true,
    lightOpacity = 15,
    breakable = false,
    placeable = false,
    alpha = 1
  },
  [Constants.BLOCK.WOOD] = {
    name = 'Wood',
    color = { .58, .42, .24 },
    solid = true,
    opaque = true,
    lightOpacity = 15,
    breakable = true,
    placeable = true,
    alpha = 1
  },
  [Constants.BLOCK.LEAF] = {
    name = 'Leaf',
    color = { .23, .55, .24 },
    solid = true,
    opaque = false,
    lightOpacity = Constants.LIGHTING.leafOpacity,
    breakable = true,
    placeable = true,
    alpha = .92
  },
  [Constants.BLOCK.SAND] = {
    name = 'Sand',
    color = { .82, .76, .52 },
    solid = true,
    opaque = true,
    lightOpacity = 15,
    breakable = true,
    placeable = true,
    alpha = 1
  },
  [Constants.BLOCK.WATER] = {
    name = 'Water',
    color = { .22, .44, .88 },
    solid = false,
    collidable = false,
    render = true,
    opaque = false,
    lightOpacity = 1,
    breakable = true,
    placeable = true,
    alpha = .74
  },
  [Constants.ITEM.SWORD] = {
    name = 'Sword',
    color = { .76, .78, .84 },
    solid = false,
    opaque = false,
    lightOpacity = 0,
    breakable = false,
    placeable = false,
    alpha = 1
  }
}

Constants.INVENTORY_SLOT_COUNT = 8
Constants.INVENTORY_START_COUNT = 48
Constants.HOTBAR_DEFAULTS = {
  { block = Constants.ITEM.SWORD, count = 1 },
  Constants.BLOCK.GRASS,
  Constants.BLOCK.DIRT,
  Constants.BLOCK.STONE,
  Constants.BLOCK.SAND,
  Constants.BLOCK.WATER,
  Constants.BLOCK.WOOD,
  Constants.BLOCK.LEAF
}

Constants.COMBAT = {
  handDamage = 1,
  swordDamage = 4
}

Constants.MOBS = {
  enabled = true,
  maxSheep = 2,
  maxGhosts = 1,
  sheepSpawnIntervalSeconds = 14,
  ghostSpawnIntervalSeconds = 20,
  spawnMinDistance = 10,
  spawnMaxDistance = 24,
  despawnDistance = 52,
  sheepSpeed = 1.2,
  ghostSpeed = 2.2,
  ghostAttackRange = 1.25,
  ghostAttackDamage = 2,
  ghostAttackCooldownSeconds = 1.4,
  aiTickSeconds = 0.20,
  maxAiTicksPerFrame = 2,
  skipAiWhenDirtyQueueAbove = 120,
  nightDaylightThreshold = 0.30
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

Constants.STATS = {
  maxHealth = 20,
  maxHunger = 20,
  startHealth = 20,
  startHunger = 20,
  startExperience = 0,
  startLevel = 0,
  hungerDrainPerSecond = 0.02,
  healthRegenThreshold = 15,
  healthRegenIntervalSeconds = 4.0,
  healthRegenAmount = 1.0,
  respawnInvulnerabilitySeconds = 2.0
}

return Constants
