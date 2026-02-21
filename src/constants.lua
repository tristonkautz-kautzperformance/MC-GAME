local Constants = {}

Constants.WORLD_SIZE_X = 1280
Constants.WORLD_SIZE_Z = 1280
Constants.WORLD_SIZE_Y = 96
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
  mountainBiomeFrequency = 0.0028,
  mountainBiomeOctaves = 2,
  mountainBiomeThreshold = 0.52,
  mountainRidgeFrequency = 0.0085,
  mountainRidgeOctaves = 3,
  mountainRidgePersistence = 0.55,
  mountainHeightBoost = 20,
  mountainHeightAmplitude = 52,
  mountainStoneStartY = 58,
  mountainStoneTransition = 8,
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
Constants.SKY_BODIES = {
  enabled = true,
  distance = 260,
  sunSize = 18,
  moonSize = 16,
  orbitTiltDegrees = 22,
  moonAlpha = 0.96
}

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
  -- Limit queue stale-scan work per dequeue call to avoid rare long light-stage spikes.
  dequeueScanLimitPerCall = 512,
  -- Spread expensive sky-column recompute over multiple light ops.
  columnRecomputeRowsPerSlice = 8,
  columnRecomputeSliceMillis = 0.20,
  -- Hard ceiling on sky-flood ops in a single updateSkyLight pass (0 disables cap).
  floodOpsCapPerPass = 192,
  -- A/B spike diagnostic: cap sky-light update passes per frame.
  maxPassesPerFrame = 2,
  chunkEnsureOps = 384,
  chunkEnsureMillis = 0.2,
  chunkEnsurePasses = 2,
  chunkEnsureSpikeSoftMs = 12,
  chunkEnsureSpikeHardMs = 20,
  chunkEnsureSpikeSoftScale = 0.5,
  chunkEnsureSpikeHardScale = 0.35,
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
  drawRadiusChunks = 16,
  -- Reserved for gameplay tick radius; runtime is currently locked to 4 chunks.
  simulationRadiusChunks = 4,
  fovDegrees = 110,
  fovPaddingDegrees = 8,
  horizontalOnly = true,
  alwaysVisiblePaddingChunks = 1,
  meshCachePaddingChunks = 2
}

Constants.FOG = {
  enabled = true,
  -- If startDistance is nil, it derives from endDistance * startRatio.
  -- startDistance = 0,
  -- If endDistance is nil, it derives from draw radius minus endPaddingBlocks.
  -- endDistance = 0,
  startRatio = 0.72,
  endPaddingBlocks = 4,
  strength = 1.0
}

Constants.MESH = {
  greedy = true,
  indexed = false
}

Constants.RENDER = {
  cullOpaque = true,
  cullAlpha = false,
  -- Keep opaque ordering unsorted by default to reduce CPU sort cost at high chunk counts.
  sortOpaqueFrontToBack = false,
  -- Resort alpha chunk order only after moving this many world units (0 = every movement delta).
  alphaOrderResortStep = 1.0
}

Constants.THREAD_MESH = {
  enabled = true,
  workerCount = 0, -- 0 = auto (use logical cores - 1, clamped by maxWorkers)
  maxWorkers = 4,
  haloBlob = true,
  resultBlob = true,
  -- Limit expensive per-chunk main-thread prep before dispatching worker jobs.
  maxQueuePrepPerFrame = 1,
  maxQueuePrepMillis = 0.8,
  maxInFlight = 2,
  -- Cap how many worker results are applied on the main thread each frame.
  maxApplyResultsPerFrame = 1,
  maxApplyMillis = 0.6
}

Constants.REBUILD = {
  maxPerFrame = 10,
  maxMillisPerFrame = 1.2,
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
  WATER = 8,
  WORKBENCH = 9
}

Constants.ITEM = {
  -- Legacy sword id kept for save compatibility.
  SWORD = 1001,
  STICK = 1101,
  FLINT = 1102,
  BERRY = 1103,
  FLINT_SWORD = 1201,
  FLINT_AXE = 1202,
  FLINT_PICKAXE = 1203,
  STONE_SWORD = 1301,
  STONE_AXE = 1302,
  STONE_PICKAXE = 1303
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
    opaque = true,
    lightOpacity = Constants.LIGHTING.leafOpacity,
    breakable = true,
    placeable = true,
    alpha = 1
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
    lightOpacity = 0,
    breakable = true,
    placeable = true,
    alpha = .74
  },
  [Constants.BLOCK.WORKBENCH] = {
    name = 'Workbench',
    color = { .53, .37, .20 },
    solid = true,
    opaque = true,
    lightOpacity = 15,
    breakable = true,
    placeable = true,
    alpha = 1
  },
  [Constants.ITEM.SWORD] = {
    name = 'Sword',
    color = { .76, .78, .84 },
    solid = false,
    opaque = false,
    lightOpacity = 0,
    breakable = false,
    placeable = false,
    alpha = 1,
    stackable = false,
    toolType = 'sword',
    maxDurability = 80
  },
  [Constants.ITEM.STICK] = {
    name = 'Stick',
    color = { .60, .45, .28 },
    solid = false,
    opaque = false,
    lightOpacity = 0,
    breakable = false,
    placeable = false,
    alpha = 1
  },
  [Constants.ITEM.FLINT] = {
    name = 'Flint',
    color = { .45, .45, .48 },
    solid = false,
    opaque = false,
    lightOpacity = 0,
    breakable = false,
    placeable = false,
    alpha = 1
  },
  [Constants.ITEM.BERRY] = {
    name = 'Berry',
    color = { .82, .15, .26 },
    solid = false,
    opaque = false,
    lightOpacity = 0,
    breakable = false,
    placeable = false,
    alpha = 1,
    food = 5
  },
  [Constants.ITEM.FLINT_SWORD] = {
    name = 'Flint Sword',
    color = { .71, .73, .78 },
    solid = false,
    opaque = false,
    lightOpacity = 0,
    breakable = false,
    placeable = false,
    alpha = 1,
    stackable = false,
    toolType = 'sword',
    maxDurability = 80
  },
  [Constants.ITEM.FLINT_AXE] = {
    name = 'Flint Axe',
    color = { .67, .70, .76 },
    solid = false,
    opaque = false,
    lightOpacity = 0,
    breakable = false,
    placeable = false,
    alpha = 1,
    stackable = false,
    toolType = 'axe',
    maxDurability = 80
  },
  [Constants.ITEM.FLINT_PICKAXE] = {
    name = 'Flint Pickaxe',
    color = { .68, .72, .79 },
    solid = false,
    opaque = false,
    lightOpacity = 0,
    breakable = false,
    placeable = false,
    alpha = 1,
    stackable = false,
    toolType = 'pickaxe',
    maxDurability = 80
  },
  [Constants.ITEM.STONE_SWORD] = {
    name = 'Stone Sword',
    color = { .60, .61, .64 },
    solid = false,
    opaque = false,
    lightOpacity = 0,
    breakable = false,
    placeable = false,
    alpha = 1,
    stackable = false,
    toolType = 'sword',
    maxDurability = 160
  },
  [Constants.ITEM.STONE_AXE] = {
    name = 'Stone Axe',
    color = { .57, .58, .62 },
    solid = false,
    opaque = false,
    lightOpacity = 0,
    breakable = false,
    placeable = false,
    alpha = 1,
    stackable = false,
    toolType = 'axe',
    maxDurability = 160
  },
  [Constants.ITEM.STONE_PICKAXE] = {
    name = 'Stone Pickaxe',
    color = { .56, .58, .63 },
    solid = false,
    opaque = false,
    lightOpacity = 0,
    breakable = false,
    placeable = false,
    alpha = 1,
    stackable = false,
    toolType = 'pickaxe',
    maxDurability = 160
  }
}

Constants.BLOCK_BREAK_REQUIREMENTS = {
  [Constants.BLOCK.WOOD] = 'axe',
  [Constants.BLOCK.STONE] = 'pickaxe'
}

Constants.BLOCK_BREAK_TIME_SECONDS = {
  default = 0.55,
  [Constants.BLOCK.GRASS] = 0.45,
  [Constants.BLOCK.DIRT] = 0.48,
  [Constants.BLOCK.SAND] = 0.45,
  [Constants.BLOCK.LEAF] = 0.32,
  [Constants.BLOCK.WATER] = 0.30,
  [Constants.BLOCK.WOOD] = 0.90,
  [Constants.BLOCK.STONE] = 1.10,
  [Constants.BLOCK.WORKBENCH] = 0.90
}

Constants.BLOCK_BREAK_SPECIAL = {
  naturalTreeCascade = true,
  naturalTreeMaxBlocks = 192,
  stoneCascadeChance = 0.50,
  stoneCascadeMin = 5,
  stoneCascadeMax = 10
}

Constants.ITEM_ENTITIES = {
  maxActive = 384,
  maxDistance = 96,
  drawDistance = 80,
  pickupRadius = 0.33,
  pickupReach = 6.0,
  itemSize = 0.22,
  gravity = 24,
  airDrag = 1.8,
  groundFriction = 14,
  bounce = 0.18,
  restSpeed = 0.08,
  scatterHorizontalMin = 0.9,
  scatterHorizontalMax = 1.8,
  scatterUpMin = 1.4,
  scatterUpMax = 2.3,
  ambientSpawnRadiusChunks = 1,
  ambientMinPerChunk = 1,
  ambientMaxPerChunk = 3
}

Constants.CRAFTING = {
  bagSlotCount = 2,
  workbenchSlotCount = 25,
  bagRecipes = {
    {
      output = { id = Constants.BLOCK.WORKBENCH, count = 1 },
      ingredients = { [Constants.BLOCK.WOOD] = 4 }
    },
    {
      output = { id = Constants.ITEM.FLINT_SWORD, count = 1, durability = 80 },
      ingredients = { [Constants.ITEM.FLINT] = 2, [Constants.ITEM.STICK] = 1 }
    },
    {
      output = { id = Constants.ITEM.FLINT_AXE, count = 1, durability = 80 },
      ingredients = { [Constants.ITEM.FLINT] = 2, [Constants.ITEM.STICK] = 2 }
    },
    {
      output = { id = Constants.ITEM.FLINT_PICKAXE, count = 1, durability = 80 },
      ingredients = { [Constants.ITEM.FLINT] = 3, [Constants.ITEM.STICK] = 2 }
    }
  },
  workbenchRecipes = {
    {
      output = { id = Constants.ITEM.STONE_SWORD, count = 1, durability = 160 },
      ingredients = { [Constants.BLOCK.STONE] = 2, [Constants.ITEM.STICK] = 1, [Constants.ITEM.FLINT] = 1 }
    },
    {
      output = { id = Constants.ITEM.STONE_AXE, count = 1, durability = 160 },
      ingredients = { [Constants.BLOCK.STONE] = 2, [Constants.ITEM.STICK] = 2, [Constants.ITEM.FLINT] = 1 }
    },
    {
      output = { id = Constants.ITEM.STONE_PICKAXE, count = 1, durability = 160 },
      ingredients = { [Constants.BLOCK.STONE] = 3, [Constants.ITEM.STICK] = 2, [Constants.ITEM.FLINT] = 1 }
    }
  }
}

Constants.HOTBAR_SLOT_COUNT = 8
Constants.INVENTORY_STORAGE_SLOT_COUNT = 24
Constants.INVENTORY_SLOT_COUNT = Constants.HOTBAR_SLOT_COUNT + Constants.INVENTORY_STORAGE_SLOT_COUNT
Constants.INVENTORY_START_COUNT = 0
Constants.HOTBAR_DEFAULTS = {}

Constants.COMBAT = {
  handDamage = 1,
  swordDamage = 4
}

Constants.MOBS = {
  enabled = true,
  -- Keep mob systems wired, but disable current mob spawns for now.
  maxSheep = 0,
  maxGhosts = 0,
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
