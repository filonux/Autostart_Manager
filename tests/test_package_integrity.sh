#!/bin/bash
set -uE -o pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pass=0 fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"; ((pass++))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"; ((fail++))
    fi
}

original=(
  LICENSE.txt assets/icon2.png assets/icon3.png
)
while read -r hash rel; do
    [[ -z "$hash" ]] && continue
    check "immutable original unchanged: $rel" "$(printf '%s  %s\n' "$hash" "$ROOT_DIR/$rel" | sha256sum -c - 2>/dev/null | sed -n 's/: OK//p')" "$ROOT_DIR/$rel"
done <<'HASHES'
2c4f3b25fabad2e72170075d6459c4d66663498e083bbaa6114ca0b22b9ea34a  LICENSE.txt
f605e109556ab499a04357de242b6fe4e1e6055c679e9d0c35a01f67778e917d  assets/icon2.png
b3576c18003c549fc9575ff19f1aa52a7690dd8cedbd297d8092459371723d9c  assets/icon3.png
HASHES


# Exact tree contract: all paths from the supplied project. The repository carries no configuration files
# (no .shellcheckrc, no .gitignore).
expected=(
  .github/CODE_OF_CONDUCT.md .github/CONTRIBUTING.md .github/ISSUE_TEMPLATE/bug_report.md
  .github/ISSUE_TEMPLATE/custom.md .github/ISSUE_TEMPLATE/feature_request.md
  .github/PULL_REQUEST_TEMPLATE.md .github/SECURITY.md .github/workflows/quality.yml LICENSE.txt
  README.md README.es.md
  assets/autostart-manager.png assets/icon1.png assets/icon2.png assets/icon3.png assets/icon4.png
  assets/screenshots/EN/1-menu-AutostartManager-en.png
  assets/screenshots/EN/2-AutostartManager-startupapps-en.png
  assets/screenshots/EN/3-AutostartManager-background-en.png
  assets/screenshots/EN/4-AutostartManager-applicationservices-en.png
  assets/screenshots/EN/5-AutostartManager-systemservices-en.png
  assets/screenshots/EN/6-AutostartManager-allcategories-en.png
  assets/screenshots/ES/1-menu-AutostartManager-es.png
  assets/screenshots/ES/2-AutostartManager-programasinicio-es.png
  assets/screenshots/ES/3-AutostartManager-procesossegplano-es.png
  assets/screenshots/ES/4-AutostartManager-serviciosapps-es.png
  assets/screenshots/ES/5-AutostartManager-serviciossistema-es.png
  assets/screenshots/ES/6-AutostartManager-todascategorias-es.png
  script/Autostart_Manager.sh tests/test_function_contracts.sh tests/test_hardening.sh tests/test_icon.sh
  tests/test_language_invariance.sh
  tests/test_language_switch.sh tests/test_navigation_language.sh tests/test_package_integrity.sh tests/test_documents.sh tests/test_quality_regression.sh tests/test_readme_links.sh
  tests/test_suite_quality.sh tests/test_translation_quality.sh tests/test_ui_aesthetic.sh tests/run_all.sh
  tests/test_ui_smoke.sh tests/test_user_simulation.sh tests/lint.sh tests/test_static_analysis.sh
  tests/test_install.sh tests/test_uninstall.sh tests/test_ci_workflow.sh tests/test_hygiene.sh tests/test_compat.sh tests/test_zenity_compat.sh tests/ui_tour.sh
)
if (( $(printf '%s\n' "${expected[@]}" | sort | uniq -d | wc -l) != 0 )); then
    printf 'FAIL: expected project contract contains duplicate paths\n'
    ((fail++))
else
    printf 'PASS: expected project contract has no duplicate paths\n'
    ((pass++))
fi
mapfile -t actual < <(cd "$ROOT_DIR" && find . -path ./.git -prune -o -type f -printf '%P\n' | sort)
expected_sorted=$(printf '%s\n' "${expected[@]}" | sort | tr '\n' '|')
actual_sorted=$(printf '%s\n' "${actual[@]}" | sort | tr '\n' '|')
check 'exact project file set is preserved' "$actual_sorted" "$expected_sorted"

# A zip keeps the author's modes; git only keeps the executable bit, so exact
# modes are checked on extracted packages and invariants everywhere.
if [[ -e "$ROOT_DIR/.git" ]]; then
    printf 'SKIP: exact file modes are not preserved by git checkouts.\n'
else
    for rel in "${original[@]}"; do
        expected_mode=644
        [[ "$rel" == script/Autostart_Manager.sh ]] && expected_mode=664
        check "original mode preserved: $rel" "$(stat -c '%a' "$ROOT_DIR/$rel")" "$expected_mode"
    done
    for rel in "${expected[@]}"; do
        expected_mode=644
        [[ "$rel" == script/Autostart_Manager.sh ]] && expected_mode=664
        [[ "$rel" == tests/*.sh ]] && expected_mode=755
        check "project mode preserved: $rel" "$(stat -c '%a' "$ROOT_DIR/$rel")" "$expected_mode"
    done
fi
check 'no project file is writable by others' "$(cd "$ROOT_DIR" && find . -path ./.git -prune -o -type f -perm -o+w -print | wc -l)" 0

printf '\n%d tests: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
(( fail == 0 ))
