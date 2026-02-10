return {
  tag = 'texture-metadata',
  summary = 'Get the format of the Texture.',
  description = 'Returns the format of the texture.',
  arguments = {},
  returns = {
    format = {
      type = 'TextureFormat',
      description = 'The format of the Texture.'
    },
    linear = {
      type = 'boolean',
      description = 'Whether the format is linear or srgb.'
    }
  },
  variants = {
    {
      arguments = {},
      returns = { 'format', 'linear' }
    }
  }
}
