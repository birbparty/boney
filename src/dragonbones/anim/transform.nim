## DbTransform ↔ Mat3 conversion for DragonBones 2D skeletal animation.
##
## DbTransform uses skew-based affine representation (degrees).
## For pure rotation: skX ≈ skY ≈ rotation angle.
## Matrix is column-major (vmath convention): M[col*3 + row].

import std/math
import vmath
import dragonbones/model/model

const DegToRad* = float32(PI / 180.0)

proc dbTransformToMat3*(t: DbTransform): Mat3 =
  ## Convert a DbTransform to a column-major affine Mat3.
  ##
  ## The resulting matrix encodes the full 2D affine transform:
  ##   [scX*cos(skY)   -scY*sin(skX)   tx]
  ##   [scX*sin(skY)    scY*cos(skX)   ty]
  ##   [0               0               1]
  ##
  ## Identity: DbTransform(scX:1, scY:1, everything else 0) → mat3Identity.
  let cosSkY = cos(t.skY * DegToRad)
  let sinSkY = sin(t.skY * DegToRad)
  let cosSkX = cos(t.skX * DegToRad)
  let sinSkX = sin(t.skX * DegToRad)
  # vmath mat3(a,b,c, d,e,f, g,h,i) stores col0=[a,b,c], col1=[d,e,f], col2=[g,h,i]
  mat3(t.scX * cosSkY, t.scX * sinSkY, 0.0'f32,
       -t.scY * sinSkX, t.scY * cosSkX, 0.0'f32,
       t.x, t.y, 1.0'f32)
