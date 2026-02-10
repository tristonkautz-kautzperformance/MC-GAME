return {
  summary = 'A mesh Shape.',
  description = 'A type of `Shape` that can be used for triangle meshes.',
  extends = 'Shape',
  notes = [[
    If a `Collider` contains a MeshShape, it will be forced to become kinematic.  `ConvexShape` can
    be used instead for dynamic mesh colliders.
  ]],
  constructors = {
    'lovr.physics.newMeshShape',
    'World:newMeshCollider'
  }
}
