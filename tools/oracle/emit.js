#!/usr/bin/env node
// Headless DragonBones world-transform oracle.
//
// Loads tests/fixtures/sample/dragon_ske.json, applies the named animation
// at each sample frame, and emits bone world transforms as JSON to stdout.
//
// Usage:
//   node emit.js [--asset <path>] [--armature <name>] [--animation <name>]
//                [--frames <n,n,n,...>]
//
// The output is the golden reference for boney's deterministic sampling tests.

'use strict';

const fs   = require('fs');
const path = require('path');

// ── CLI args ──────────────────────────────────────────────────────────────────

const argv = process.argv.slice(2);
function arg(flag, def) {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : def;
}

const ASSET_PATH = arg('--asset',
  path.resolve(__dirname, '../../tests/fixtures/sample/dragon_ske.json'));
const ARMATURE_NAME = arg('--armature', 'Dragon');
const ANIMATION_NAME = arg('--animation', 'idle');
const FRAMES = (arg('--frames', '0,6,12,18,24')).split(',').map(Number);

// ── Transform math ────────────────────────────────────────────────────────────

const D2R = Math.PI / 180;

// Build a 2-D affine matrix from a DragonBones DbTransform.
// skX = rotation (degrees); skY = skew (degrees, usually equals skX).
// Matrix layout: { a, b, c, d, tx, ty } where:
//   [a  c  tx]
//   [b  d  ty]
//   [0  0   1]
function toMatrix(x = 0, y = 0, skX = 0, skY = skX, scX = 1, scY = 1) {
  return {
    a:  scX * Math.cos(skY * D2R),
    b:  scX * Math.sin(skY * D2R),
    c: -scY * Math.sin(skX * D2R),
    d:  scY * Math.cos(skX * D2R),
    tx: x,
    ty: y,
  };
}

const IDENTITY = toMatrix();

// Multiply parent * child (world = parent * local).
function multiply(p, c) {
  return {
    a:  p.a * c.a + p.c * c.b,
    b:  p.b * c.a + p.d * c.b,
    c:  p.a * c.c + p.c * c.d,
    d:  p.b * c.c + p.d * c.d,
    tx: p.a * c.tx + p.c * c.ty + p.tx,
    ty: p.b * c.tx + p.d * c.ty + p.ty,
  };
}

// Decompose a world matrix into the canonical transform representation.
function fromMatrix(m) {
  return {
    x:        m.tx,
    y:        m.ty,
    rotation: Math.atan2(m.b, m.a) / D2R,
    scaleX:   Math.sqrt(m.a * m.a + m.b * m.b),
    scaleY:   Math.sqrt(m.c * m.c + m.d * m.d),
    matrix:   { a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty },
  };
}

// ── Keyframe interpolation ────────────────────────────────────────────────────

// Collect keyframes from a timeline array, building cumulative frame positions.
// Each entry is { startFrame, endFrame, tweenEasing, fields... }.
function buildKeyframes(timeline) {
  const kf = [];
  let cursor = 0;
  for (let i = 0; i < timeline.length; i++) {
    const entry = timeline[i];
    const start = cursor;
    const dur   = (entry.duration === undefined) ? 0 : entry.duration;
    kf.push({ startFrame: start, endFrame: start + dur, ...entry });
    cursor += dur;
  }
  return kf;
}

// Interpolate a single scalar field across keyframes at the given frame.
function interpolateField(keyframes, frame, field) {
  if (!keyframes || keyframes.length === 0) return 0;

  for (let i = 0; i < keyframes.length - 1; i++) {
    const kA = keyframes[i];
    const kB = keyframes[i + 1];
    if (frame >= kA.startFrame && frame <= kA.endFrame) {
      const span = kA.endFrame - kA.startFrame;
      const vA   = kA[field] || 0;
      const vB   = kB[field] || 0;
      if (span <= 0 || kA.tweenEasing === undefined || kA.tweenEasing === null) {
        // Step tween (no interpolation)
        return vA;
      }
      // Linear tween (tweenEasing: 0 = linear)
      const t = (frame - kA.startFrame) / span;
      // Bezier curve support would go here; for now only linear (easing=0) is used.
      return vA + t * (vB - vA);
    }
  }
  // Past the last keyframe — clamp to last value
  return (keyframes[keyframes.length - 1][field]) || 0;
}

// ── Animation sampling ────────────────────────────────────────────────────────

// Compute a bone's local transform at `frame`, given its animation data and
// its bind-pose default transform from the skeleton definition.
function localAtFrame(boneDefault, boneAnim, frame) {
  if (!boneAnim) {
    // No animation for this bone — use bind-pose transform.
    const d = boneDefault.transform || {};
    return toMatrix(d.x || 0, d.y || 0,
                    d.skX || 0, d.skY !== undefined ? d.skY : (d.skX || 0),
                    d.scX !== undefined ? d.scX : 1, d.scY !== undefined ? d.scY : 1);
  }

  // Animated transform: pull each channel from keyframes.
  const rotKFs  = buildKeyframes(boneAnim.rotateFrame    || []);
  const transKFs = buildKeyframes(boneAnim.translateFrame || []);
  const scaleKFs = buildKeyframes(boneAnim.scaleFrame     || []);

  const defT = boneDefault.transform || {};
  const baseX    = defT.x   || 0;
  const baseY    = defT.y   || 0;
  const baseSkX  = defT.skX || 0;
  const baseSkY  = defT.skY !== undefined ? defT.skY : baseSkX;
  const baseScX  = defT.scX !== undefined ? defT.scX : 1;
  const baseScY  = defT.scY !== undefined ? defT.scY : 1;

  // Animation values are applied ON TOP of the bind-pose.
  const dRotate = interpolateField(rotKFs,   frame, 'rotate');
  const dTransX = interpolateField(transKFs, frame, 'x');
  const dTransY = interpolateField(transKFs, frame, 'y');
  const dScaleX = interpolateField(scaleKFs, frame, 'x');
  const dScaleY = interpolateField(scaleKFs, frame, 'y');

  // Rotation keyframes contain absolute rotation in DragonBones 5.x.
  // Translation / scale keyframes contain deltas (offsets from bind pose).
  const finalX   = baseX + dTransX;
  const finalY   = baseY + dTransY;
  const finalSkX = dRotate;      // rotate keyframes are absolute bone rotation
  const finalSkY = dRotate;      // no skew in our sample
  const finalScX = baseScX + dScaleX;
  const finalScY = baseScY + dScaleY;

  return toMatrix(finalX, finalY, finalSkX, finalSkY, finalScX, finalScY);
}

// ── Main ──────────────────────────────────────────────────────────────────────

const raw        = JSON.parse(fs.readFileSync(ASSET_PATH, 'utf8'));
const armDef     = raw.armature.find(a => a.name === ARMATURE_NAME);
if (!armDef) { console.error(`armature "${ARMATURE_NAME}" not found`); process.exit(1); }

const animDef    = armDef.animation.find(a => a.name === ANIMATION_NAME);
if (!animDef) { console.error(`animation "${ANIMATION_NAME}" not found`); process.exit(1); }

// Map bone name → animation bone entry.
const animBoneMap = {};
for (const b of (animDef.bone || [])) animBoneMap[b.name] = b;

// Build a parent-ordered list of bones (root first).
// DragonBones bone arrays are already in topological order.
const bones = armDef.bone;

// Sample each requested frame.
const samples = FRAMES.map(frame => {
  // World matrices: computed root → leaf.
  const worldMatrices = {};

  for (const bone of bones) {
    const parentMatrix = bone.parent ? worldMatrices[bone.parent] : IDENTITY;
    const local        = localAtFrame(bone, animBoneMap[bone.name], frame);
    worldMatrices[bone.name] = multiply(parentMatrix, local);
  }

  // Decompose to human-readable transforms.
  const boneTransforms = {};
  for (const bone of bones) {
    boneTransforms[bone.name] = fromMatrix(worldMatrices[bone.name]);
  }

  return { frame, time: frame / (armDef.frameRate || raw.frameRate), bones: boneTransforms };
});

const output = {
  version:   '1',
  asset:     path.relative(path.resolve(__dirname, '../..'), ASSET_PATH),
  armature:  ARMATURE_NAME,
  animation: ANIMATION_NAME,
  frameRate: armDef.frameRate || raw.frameRate,
  duration:  animDef.duration,
  samples,
};

process.stdout.write(JSON.stringify(output, null, 2) + '\n');
