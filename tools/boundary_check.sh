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
#      characters, under an allocator's or `std.mem`'s `print`, or the deprecated `allocPrint`/`bufPrint`), and structural key arithmetic. Any hit
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
#   3. The engines' imports. `src/ui/` and `src/ecs/` are packages of their own (each with its
#      `build.zig.zon`); an import in either of anything but `std`, `builtin` or that package's
#      own files fails.
#
#   4. Pages lay out; only templates paint. A page (a file under `src/pages/` outside
#      `templates/`) places nodes — `div`, `spacer`, `with_size`/`with_flow`/`with_gap`/
#      `with_layout`, or `box`/`leaf`/`set` with an empty style spec `.{}` — and composes the
#      shelf; a styled, text or `label` node belongs to a template
#      (`src/pages/templates/copy.zig` holds the prose leaves), because a style chosen in a
#      page is art direction that drifts. The debug page is exempt:
#      the audit harness paints by design, and so are the helpers beside the pages, which build
#      no nodes. Any hit fails the check.
#
# Run from anywhere: `sh tools/boundary_check.sh`. Exit 0 when clean, 1 on a failure.

cd "$(dirname "$0")/.." || exit 2

status=0
scope="src/pages src/ui_client/modal.zig src/ui_client/tooltip.zig src/ui_client/text_input.zig"

hard='registerFocus\(|registerRovingFocus\(|publishControlState\(|(allocPrint|bufPrint|mem\.print|arena\.print|\ba\.print)\([^"]*"([a-z_]|\{[sd]\})*\{d\}([a-z_]|\{[sd]\})*"|ha\.ui\.key(_i)?\(|retainState\('
hits=$(grep -rnE "$hard" $scope --include='*.zig' | grep -vE '^[^:]+:[0-9]+:\s*//')
if [ -n "$hits" ]; then
    echo "boundary: lifecycle wiring, formatted ids or key arithmetic in a page or template:"
    echo "$hits"
    status=1
fi

paint='\.with_style\(|\.text(_fit)?\(|\.label(_fit)?\('
# The helpers beside the pages (`body`, `eating`, `query`, `hex_pixel`) build no nodes: they are
# math a page or template reads, and `query`'s `row.text(...)` is a field read, not a text leaf.
pages=$(find src/pages -name '*.zig' -not -path 'src/pages/templates/*' -not -name debug_page.zig \
    -not -name body.zig -not -name eating.zig -not -name query.zig -not -name hex_pixel.zig)
hits=$(grep -nE "$paint" $pages | grep -vE '^[^:]+:[0-9]+:\s*//')
# A `Props` constructor or `set` paints when its style spec (the last argument) is not `.{}`.
# A call wrapped over lines is flagged at its first line, so keep a page's calls on one.
styled=$(grep -nE '\.(box|boxi|leaf|leafi|set)\(.*\.\{' $pages | grep -vE '^[^:]+:[0-9]+:\s*//' | grep -vE ', \.\{\}\);\s*(//.*)?$')
hits=$(printf '%s\n%s' "$hits" "$styled" | grep -v '^$')
if [ -n "$hits" ]; then
    echo "boundary: a page paints (a styled or text node belongs to a template):"
    echo "$hits"
    status=1
fi

inventory='\.pass_through\(\)|\.pass_through = true|\.probe\(\)|setPassThrough\(|prior_geometry\(|\.rect\((parent\.)?ctx\)|rectOf\(|priorGeometry(Of)?\(|with_size_px\(|with_offset_px\(|view\.dp\(|capturePointer\(|releasePointerCapture\(|semantics\.publish\(|cursor\.request\(|requestFocus\(|consumeFlag\('
# Components that own geometry or a host service, the game's dialog shell, and the debug page
# (its tooltip fixture is placed and clamped like a production tooltip). A template test file
# (`*_test.zig`) reads stamped geometry to aim its synthetic pointer.
approved='^src/(ui_client/(modal|tooltip|text_input)\.zig|pages/templates/(scroll_view|slider|terminal|tabs|capital_row|eating_policy|modal|catalog_controls|research_board|[a-z_]+_test)\.zig|pages/debug_page\.zig):'
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
for pkg in src/ui src/ecs; do
    engine=$(grep -rnE '@import\("[^"]+"\)' "$pkg" --include='*.zig' | grep -vE '^[^:]+:[0-9]+:\s*//' |
        while IFS=: read -r file line text; do
            printf '%s\n' "$text" | grep -oE '@import\("[^"]+"\)' | while read -r match; do
                target=${match#@import(\"}
                target=${target%\")}
                case "$target" in
                    std | builtin) continue ;;
                    *.zig | *.zon)
                        case "$(realpath -m "$(dirname "$file")/$target")" in
                            "$root"/"$pkg"/*) continue ;;
                        esac
                        ;;
                esac
                echo "$file:$line: $match"
            done
        done)
    if [ -n "$engine" ]; then
        echo "boundary: the engine imports something outside $pkg:"
        echo "$engine"
        status=1
    fi
done

exit $status
