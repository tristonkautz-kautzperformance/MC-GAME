return {
  summary = 'Get the pose of the Shape.',
  description = [[
    Returns the position and orientation of the Shape in world space, taking into the account the
    position and orientation of the Collider it's attached to, if any.  Shapes that aren't attached
    to a Collider will return their local offset.
  ]],
  arguments = {},
  returns = {
    x = {
      type = 'number',
      description = 'The x position of the Shape, in meters.'
    },
    y = {
      type = 'number',
      description = 'The y position of the Shape, in meters.'
    },
    z = {
      type = 'number',
      description = 'The z position of the Shape, in meters.'
    },
    angle = {
      type = 'number',
      description = 'The number of radians the Shape is rotated around its axis of rotation.'
    },
    ax = {
      type = 'number',
      description = 'The x component of the axis of rotation.'
    },
    ay = {
      type = 'number',
      description = 'The y component of the axis of rotation.'
    },
    az = {
      type = 'number',
      description = 'The z component of the axis of rotation.'
    }
  },
  variants = {
    {
      arguments = {},
      returns = { 'x', 'y', 'z', 'angle', 'ax', 'ay', 'az' }
    }
  },
  related = {
    'Shape:getPosition',
    'Shape:getOrientation',
    'Shape:getOffset',
    'Shape:setOffset'
  }
}
