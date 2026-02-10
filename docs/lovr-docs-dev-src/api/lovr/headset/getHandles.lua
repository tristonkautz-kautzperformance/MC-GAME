return {
  tag = 'headset-misc',
  summary = 'Get native pointers to OpenXR objects.',
  description = [[
    Returns pointers to the OpenXR instance and session objects.

    This can be used with FFI or other native plugins to integrate with other OpenXR code.
  ]],
  arguments = {},
  returns = {
    instance = {
      type = 'lightuserdata',
      description = 'The OpenXR instance handle (`XrInstance`).'
    },
    session = {
      type = 'lightuserdata',
      description = 'The OpenXR session handle (`XrSession`).'
    }
  },
  variants = {
    {
      arguments = {},
      returns = { 'instance', 'session' }
    }
  }
}
