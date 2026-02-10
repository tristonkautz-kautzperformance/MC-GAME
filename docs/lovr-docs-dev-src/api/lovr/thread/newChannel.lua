return {
  summary = 'Create a new, unnamed Channel.',
  description = [[
    Creates a new unnamed `Channel` object.  Usually it's more convenient to use
    `lovr.thread.getChannel`, since other threads can use that function to query the channel by
    name.  Unnamed channels don't require a unique name, but they need to be sent to other threads
    somehow (e.g. on a different Channel or as an argument to `Thread:start`).
  ]],
  arguments = {},
  returns = {
    channel = {
      type = 'Channel',
      description = 'The new Channel.'
    }
  },
  variants = {
    {
      arguments = {},
      returns = { 'channel' }
    }
  },
  related = {
    'lovr.thread.getChannel'
  }
}
