return {
  tag = 'system-clipboard',
  summary = 'Set the clipboard text.',
  description = 'Sets the clipboard text.',
  arguments = {
    text = {
      type = 'string',
      description = 'The string to set as the clipboard text.'
    }
  },
  returns = {},
  variants = {
    {
      arguments = { 'text' },
      returns = {}
    }
  }
}
