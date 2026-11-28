#!/usr/bin/env python3
"""Turn AOSP SystemUI's PIN bouncer shapes into Dart data for Denial.

  tools/generate-keyguard-pin-shapes.py AOSP_SYSTEMUI_RES_DRAWABLE > \
      plugins/denial_desktop/lib/src/widgets/lock/keyguard_pin_shapes_data.dart

Reads pin_dot_shape_1_avd.xml .. pin_dot_shape_6_avd.xml (the shapes a PIN
digit shows as on Android 14-16, bouncer_pin_shapes) and writes their
vector groups, paths and animators. Only what those files use is supported:
groups with translate/scale/pivot/rotation, filled paths made of M, C and a
closing c, and objectAnimators on pathData, scaleX, scaleY, translateX,
translateY and rotation with cubic pathInterpolators.
"""

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

A = '{http://schemas.android.com/apk/res/android}'


def path_numbers(data):
    """Path data as (commands, numbers): M takes 2, C 6, Z none."""
    commands = []
    numbers = []
    for token in re.finditer(r'([MCc])([^MCc]*)', data.strip()):
        letter, args = token.group(1), token.group(2)
        values = [float(v) for v in re.findall(r'-?\d*\.?\d+(?:e-?\d+)?', args)]
        if letter == 'c' and not values:
            commands.append('Z')
            continue
        if letter == 'M':
            assert len(values) == 2, data
        elif letter == 'C':
            assert len(values) % 6 == 0 and values, data
        else:
            raise ValueError(f'unsupported path command {letter} in {data}')
        if letter == 'C':
            for i in range(0, len(values), 6):
                commands.append('C')
                numbers.extend(values[i:i + 6])
        else:
            commands.append('M')
            numbers.extend(values)
    return ''.join(commands), numbers


def interpolator(animator):
    found = [p.attrib[A + 'pathData'] for p in animator.iter('pathInterpolator')]
    if not found:
        return None  # Android's default: accelerate-decelerate.
    m = re.fullmatch(
        r'\s*M\s*0(?:\.0)?,\s*0(?:\.0)?\s*c\s*([-\d.]+),\s*([-\d.]+)\s+'
        r'([-\d.]+),\s*([-\d.]+)\s+1(?:\.0)?,\s*1(?:\.0)?\s*',
        found[0],
    )
    assert m, found[0]
    return tuple(float(v) for v in m.groups())


def fmt(v):
    # Always a double literal: an int would not cast to double in Dart.
    return repr(float(round(v, 4)))


def dart_list(values):
    return '[' + ', '.join(fmt(v) for v in values) + ']'


def convert(file):
    root = ET.parse(file).getroot()
    vector = next(root.iter('vector'))
    viewport = float(vector.attrib[A + 'viewportWidth'])
    animators = {}
    for target in root.findall('target'):
        name = target.attrib[A + 'name']
        for animator in target.iter('objectAnimator'):
            prop = animator.attrib[A + 'propertyName']
            if name == 'time_group':
                continue  # Only sets the drawable's length.
            entry = dict(
                start=float(animator.attrib.get(A + 'startOffset', '0')),
                duration=float(animator.attrib.get(A + 'duration', '300')),
                curve=interpolator(animator),
            )
            raw_from = animator.attrib[A + 'valueFrom']
            raw_to = animator.attrib[A + 'valueTo']
            if prop == 'pathData':
                entry['from'] = path_numbers(raw_from)[1]
                entry['to'] = path_numbers(raw_to)[1]
            else:
                entry['from'] = float(raw_from)
                entry['to'] = float(raw_to)
            animators.setdefault((name, prop), []).append(entry)

    def keyframes(name, prop):
        out = []
        for e in sorted(animators.get((name, prop), []), key=lambda e: e['start']):
            curve = 'null' if e['curve'] is None else 'Cubic(' + ', '.join(fmt(v) for v in e['curve']) + ')'
            if prop == 'pathData':
                value_from, value_to = dart_list(e['from']), dart_list(e['to'])
            else:
                value_from, value_to = fmt(e['from']), fmt(e['to'])
            out.append(
                f'AvdKeyframe(start: {fmt(e["start"])}, duration: {fmt(e["duration"])}, '
                f'from: {value_from}, to: {value_to}, curve: {curve})'
            )
        return out

    def node(element, indent):
        pad = ' ' * indent
        if element.tag == 'path':
            name = element.attrib.get(A + 'name', '')
            commands, numbers = path_numbers(element.attrib[A + 'pathData'])
            frames = keyframes(name, 'pathData')
            lines = [f"{pad}AvdPath(", f"{pad}  commands: '{commands}',", f"{pad}  numbers: {dart_list(numbers)},"]
            if frames:
                lines.append(f'{pad}  morph: [')
                lines += [f'{pad}    {f},' for f in frames]
                lines.append(f'{pad}  ],')
            lines.append(f'{pad})')
            return '\n'.join(lines)
        assert element.tag == 'group', element.tag
        name = element.attrib.get(A + 'name', '')
        if name == 'time_group':
            return None
        values = {
            key: float(element.attrib.get(A + key, default))
            for key, default in (
                ('translateX', '0'), ('translateY', '0'), ('scaleX', '1'),
                ('scaleY', '1'), ('pivotX', '0'), ('pivotY', '0'), ('rotation', '0'),
            )
        }
        lines = [f'{pad}AvdGroup(']
        for key, value in values.items():
            default = 1.0 if key.startswith('scale') else 0.0
            if value != default:
                lines.append(f'{pad}  {key}: {fmt(value)},')
        for prop in ('translateX', 'translateY', 'scaleX', 'scaleY', 'rotation'):
            frames = keyframes(name, prop)
            if frames:
                lines.append(f'{pad}  {prop}Frames: [')
                lines += [f'{pad}    {f},' for f in frames]
                lines.append(f'{pad}  ],')
        children = [c for c in (node(child, indent + 4) for child in element) if c]
        lines.append(f'{pad}  children: [')
        lines += [c + ',' for c in children]
        lines.append(f'{pad}  ],')
        lines.append(f'{pad})')
        return '\n'.join(lines)

    groups = [g for g in (node(child, 6) for child in vector) if g]
    return viewport, groups


def main():
    folder = Path(sys.argv[1])
    print('// GENERATED by tools/generate-keyguard-pin-shapes.py from AOSP')
    print('// SystemUI res/drawable/pin_dot_shape_{1..6}_avd.xml (Apache-2.0).')
    print('// Do not edit by hand.')
    print()
    print("import 'package:flutter/animation.dart' show Cubic;")
    print()
    print("import 'keyguard_pin_shapes.dart';")
    print()
    print('/// The six shapes a PIN digit appears as (bouncer_pin_shapes).')
    print('const List<AvdDrawable> keyguardPinShapes = [')
    for i in range(1, 7):
        viewport, groups = convert(folder / f'pin_dot_shape_{i}_avd.xml')
        print(f'  // pin_dot_shape_{i}_avd')
        print('  AvdDrawable(')
        print(f'    viewport: {fmt(viewport)},')
        print('    children: [')
        for g in groups:
            print(g + ',')
        print('    ],')
        print('  ),')
    print('];')


if __name__ == '__main__':
    main()
