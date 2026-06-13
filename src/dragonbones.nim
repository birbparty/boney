## DragonBones 2D skeletal animation runtime — render-agnostic core.
##
## Import this module to get the full public API:
##   import dragonbones
##
## Or import submodules directly for finer-grained dependency:
##   import dragonbones/model
##   import dragonbones/anim
##
## Module layout convention: each submodule is a *package directory*
## (e.g. src/dragonbones/model/) with a same-named aggregator file inside
## (src/dragonbones/model/model.nim). The re-exports below use
## `include dragonbones/model; export model` so `import dragonbones`
## surfaces a flat public API. Do NOT create flat src/dragonbones/model.nim
## files — use the package-dir layout to keep large subsystems extensible.

# Public re-exports — uncomment as sub-modules are implemented.
# include dragonbones/model; export model
# include dragonbones/anim;  export anim
# include dragonbones/parse; export parse
# include dragonbones/atlas; export atlas
