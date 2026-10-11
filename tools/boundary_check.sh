#!/bin/sh
# Composition boundary check — see `src/ui_client/README.md`, "Where geometry is read". It
# covers the authoring tiers (`src/pages/` and the foundation compositions in `src/ui_client/`),
# not the mechanism files beneath them.
#
# Two tiers, because an allowlist per call would be brittle:
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

exit $status
