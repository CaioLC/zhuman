#!/bin/sh
# Composition boundary check — see `src/ui_client/README.md`, "Where geometry is read". It
# covers the authoring tiers (`src/pages/` and the foundation compositions in `src/ui_client/`),
# not the mechanism files beneath them.
#
# Three tiers. The first two split hard failures from an inventory, because an allowlist per
# call would be brittle:
#
#   1. Hard failures. Protocol knowledge that has one home now and no legitimate use in a
#      page or template: the control lifecycle ritual (register focus, publish control state),
#      loop ids formatted from an index (a format string made only of `{d}`/`{s}` and id
#      characters, under `allocPrint` or `bufPrint`), and structural key arithmetic. Any hit
#      fails the check.
#
#   2. Inventory. Geometry read-back, pass-through probes, device-pixel sizing, semantic and
#      cursor publication, focus requests, pointer capture. These are allowed only inside a
#      component that owns geometry or a host service, or a page placing an overlay root; the
#      README paragraph names them. The check prints every site so an audit can compare
#      the list against that record, and fails when a site appears in a file not on the
#      approved list below. Both tiers match spellings, not types: a new way to read
#      geometry is added to the pattern here, or it goes uncounted.
#
#   3. The engine's imports. `src/ui/` is a package of its own (`src/ui/build.zig.zon`); an
#      import there of anything but `std`, `builtin` or its own files fails.
#
#   4. Pages lay out; only templates paint. A page (a file under `src/pages/` outside
#      `templates/`) places nodes — `div`, `spacer`, `with_size`/`with_flow`/`with_gap`/
#      `with_layout` — and composes the shelf; a styled or text node belongs to a template
#      (`src/pages/templates/copy.zig` holds the prose leaves), because a style chosen in a
#      page is art direction that drifts. The debug page and the mock showcase are exempt:
#      the audit harness and the style eyeball page paint by design. Any hit fails the check.
#
# Run from anywhere: `sh tools/boundary_check.sh`. Exit 0 when clean, 1 on a failure.

cd "$(dirname "$0")/.." || exit 2

status=0
scope="src/pages src/ui_client/modal.zig src/ui_client/tooltip.zig src/ui_client/text_input.zig"

hard='registerFocus\(|registerRovingFocus\(|publishControlState\(|(allocPrint|bufPrint)\([^"]*"([a-z_]|\{[sd]\})*\{d\}([a-z_]|\{[sd]\})*"|ha\.ui\.key(_i)?\(|retainState\('
hits=$(grep -rnE "$hard" $scope --include='*.zig' | grep -vE '^[^:]+:[0-9]+:\s*//')
if [ -n "$hits" ]; then
    echo "boundary: lifecycle wiring, formatted ids or key arithmetic in a page or template:"
    echo "$hits"
    status=1
fi

paint='\.with_style\(|\.text(_fit)?\('
pages=$(find src/pages -name '*.zig' -not -path 'src/pages/templates/*' -not -name debug_page.zig -not -name mock.zig)
hits=$(grep -nE "$paint" $pages | grep -vE '^[^:]+:[0-9]+:\s*//')
if [ -n "$hits" ]; then
    echo "boundary: a page paints (a styled or text node belongs to a template):"
    echo "$hits"
    status=1
fi

inventory='\.pass_through\(\)|setPassThrough\(|prior_geometry\(|\.rect\((parent\.)?ctx\)|rectOf\(|priorGeometry(Of)?\(|with_size_px\(|with_offset_px\(|view\.dp\(|capturePointer\(|releasePointerCapture\(|semantics\.publish\(|cursor\.request\(|requestFocus\(|consumeFlag\('
# Components that own geometry or a host service, the game's dialog shell, and the debug page
# (its tooltip fixture is placed and clamped like a production tooltip).
approved='^src/(ui_client/(modal|tooltip|text_input)\.zig|pages/templates/(scroll_view|action_tile|milestone_goal|slider|terminal|tabs|capital_row|eating_policy|modal|catalog_controls|select)\.zig|pages/debug_page\.zig):'
sites=$(grep -rnE "$inventory" $scope --include='*.zig' | grep -vE '^[^:]+:[0-9]+:\s*//')
echo "boundary: geometry and host-service sites (review against the roadmap's approved list):"
echo "$sites" | sed 's/^/  /'
strays=$(echo "$sites" | grep -vE "$approved")
if [ -n "$strays" ]; then
    echo "boundary: sites in files that are not approved components:"
    echo "$strays"
    status=1
fi

root=$(pwd -P)
engine=$(grep -rnE '@import\("[^"]+"\)' src/ui --include='*.zig' | grep -vE '^[^:]+:[0-9]+:\s*//' |
    while IFS=: read -r file line text; do
        printf '%s\n' "$text" | grep -oE '@import\("[^"]+"\)' | while read -r match; do
            target=${match#@import(\"}
            target=${target%\")}
            case "$target" in
                std | builtin) continue ;;
                *.zig | *.zon)
                    case "$(realpath -m "$(dirname "$file")/$target")" in
                        "$root"/src/ui/*) continue ;;
                    esac
                    ;;
            esac
            echo "$file:$line: $match"
        done
    done)
if [ -n "$engine" ]; then
    echo "boundary: the engine imports something outside src/ui:"
    echo "$engine"
    status=1
fi

exit $status
