echo "<h1>Post-Release Report (PRs that have been pushed into TEST this release cycle)</h1>"
echo "<p>Generated: $(TZ='America/Vancouver' date '+%A, %B %-d, %Y at %-I:%M %p %Z')</p>"

# bcgov/lear (whole repo)
echo "<!-- bcgov/lear -->"
echo "<h2>"
echo "bcgov/lear"
echo "</h2>"
echo "<pre>"
./post-release-watch.sh 6 business-api-cd.yml bcgov/lear test-release --html
echo "</pre>"
echo "<hr>"

# bcgov/business-filings-ui
echo "<!-- bcgov/business-filings-ui -->"
echo "<h2>"
echo "bcgov/business-filings-ui"
echo "</h2>"
echo "<pre>"
./post-release-watch.sh 6 cd.yml bcgov/business-filings-ui test-release --html
echo "</pre>"
echo "<hr>"

# bcgov/business-create-ui
echo "<!-- bcgov/business-create-ui -->"
echo "<h2>"
echo "bcgov/business-create-ui"
echo "</h2>"
echo "<pre>"
./post-release-watch.sh 6 cd.yml bcgov/business-create-ui test-release --html
echo "</pre>"
echo "<hr>"

# bcgov/business-edit-ui
echo "<!-- bcgov/business-edit-ui -->"
echo "<h2>"
echo "bcgov/business-edit-ui"
echo "</h2>"
echo "<pre>"
./post-release-watch.sh 6 cd.yml bcgov/business-edit-ui test-release --html
echo "</pre>"
echo "<hr>"

# bcgov/business-dashboard-ui
echo "<!-- bcgov/business-dashboard-ui -->"
echo "<h2>"
echo "bcgov/business-dashboard-ui"
echo "</h2>"
echo "<pre>"
./post-release-watch.sh 6 cd.yml bcgov/business-dashboard-ui test-release --html
echo "</pre>"
echo "<hr>"

# bcgov/business-ui (web/business-registry-dashboard)
echo "<!-- bcgov/business-ui web/business-registry-dashboard -->"
echo "<h2>"
echo "bcgov/business-ui (web/business-registry-dashboard)"
echo "</h2>"
echo "<pre>"
./post-release-watch.sh 6 business-registry-ui-cd.yaml bcgov/business-ui test-release --in-dirs=web/business-registry-dashboard --html
echo "</pre>"
echo "<hr>"

# bcgov/lear queue_services — one table per child dir (excluding common), shown
# last so the whole-lear table above keeps its original first position. Each is
# deployed by its own CD workflow and filtered with --in-dirs=queue_services/
# <child> so the table denotes only the PRs that changed that component.
#
# Clone lear ONCE and share it across all five tables via IN_DIRS_CLONE_DIR (see
# ensure_clone in post-release-watch.sh): the first table populates this dir, the
# other four reuse it, and we remove it afterwards. stdout is the report HTML,
# so mktemp's path is captured into the var (not printed). If the clone can't be
# made each table just falls back to its own.
LEAR_CLONE_DIR="$(mktemp -d)"
export IN_DIRS_CLONE_DIR="$LEAR_CLONE_DIR"

# bcgov/lear (queue_services/business-bn)
echo "<!-- bcgov/lear queue_services/business-bn -->"
echo "<h2>"
echo "bcgov/lear (queue_services/business-bn)"
echo "</h2>"
echo "<pre>"
./post-release-watch.sh 6 business-bn-cd.yml bcgov/lear test-release --in-dirs=queue_services/business-bn --html
echo "</pre>"
echo "<hr>"

# bcgov/lear (queue_services/business-digital-credentials)
echo "<!-- bcgov/lear queue_services/business-digital-credentials -->"
echo "<h2>"
echo "bcgov/lear (queue_services/business-digital-credentials)"
echo "</h2>"
echo "<pre>"
./post-release-watch.sh 6 business-digital-credentials-cd.yml bcgov/lear test-release --in-dirs=queue_services/business-digital-credentials --html
echo "</pre>"
echo "<hr>"

# bcgov/lear (queue_services/business-emailer)
echo "<!-- bcgov/lear queue_services/business-emailer -->"
echo "<h2>"
echo "bcgov/lear (queue_services/business-emailer)"
echo "</h2>"
echo "<pre>"
./post-release-watch.sh 6 business-emailer-cd.yml bcgov/lear test-release --in-dirs=queue_services/business-emailer --html
echo "</pre>"
echo "<hr>"

# bcgov/lear (queue_services/business-filer)
echo "<!-- bcgov/lear queue_services/business-filer -->"
echo "<h2>"
echo "bcgov/lear (queue_services/business-filer)"
echo "</h2>"
echo "<pre>"
./post-release-watch.sh 6 business-filer-cd.yml bcgov/lear test-release --in-dirs=queue_services/business-filer --html
echo "</pre>"
echo "<hr>"

# bcgov/lear (queue_services/business-pay)
echo "<!-- bcgov/lear queue_services/business-pay -->"
echo "<h2>"
echo "bcgov/lear (queue_services/business-pay)"
echo "</h2>"
echo "<pre>"
./post-release-watch.sh 6 business-pay-cd.yml bcgov/lear test-release --in-dirs=queue_services/business-pay --html
echo "</pre>"
echo "<hr>"

# Done with lear's per-dir tables — drop the shared clone.
unset IN_DIRS_CLONE_DIR
rm -rf "$LEAR_CLONE_DIR"

# Repo Versions
echo "<!-- repo versions -->"
echo "<h2>"
echo "Repo Versions"
echo "</h2>"
echo "<ul>"
echo "  <li><strong>business-edit-ui</strong>"
echo "    <ul>"
echo "      <li>$(curl -fsSL https://raw.githubusercontent.com/bcgov/business-edit-ui/main/package.json      | jq -r .version)</li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>business-filings-ui</strong>"
echo "    <ul>"
echo "      <li>$(curl -fsSL https://raw.githubusercontent.com/bcgov/business-filings-ui/main/package.json   | jq -r .version)</li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>business-create-ui</strong>"
echo "    <ul>"
echo "      <li>$(curl -fsSL https://raw.githubusercontent.com/bcgov/business-create-ui/main/package.json    | jq -r .version)</li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>business-dashboard-ui</strong>"
echo "    <ul>"
echo "      <li>$(curl -fsSL https://raw.githubusercontent.com/bcgov/business-dashboard-ui/main/package.json | jq -r .version)</li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>business-registry-dashboard</strong>"
echo "    <ul>"
echo "      <li>$(curl -fsSL https://raw.githubusercontent.com/bcgov/business-ui/refs/heads/main/web/business-registry-dashboard/package.json | jq -r .version)</li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>legal-api</strong>"
echo "    <ul>"
echo "      <li>$(curl -fsSL https://raw.githubusercontent.com/bcgov/lear/refs/heads/main/legal-api/src/legal_api/version.py | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')</li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>queue_services/business-bn</strong>"
echo "    <ul>"
echo "      <li>$(curl -fsSL https://raw.githubusercontent.com/bcgov/lear/refs/heads/main/queue_services/business-bn/pyproject.toml | grep -E '^version' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')</li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>queue_services/business-digital-credentials</strong>"
echo "    <ul>"
echo "      <li>$(curl -fsSL https://raw.githubusercontent.com/bcgov/lear/refs/heads/main/queue_services/business-digital-credentials/pyproject.toml | grep -E '^version' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')</li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>queue_services/business-emailer</strong>"
echo "    <ul>"
echo "      <li>$(curl -fsSL https://raw.githubusercontent.com/bcgov/lear/refs/heads/main/queue_services/business-emailer/pyproject.toml | grep -E '^version' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')</li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>queue_services/business-filer</strong>"
echo "    <ul>"
echo "      <li>$(curl -fsSL https://raw.githubusercontent.com/bcgov/lear/refs/heads/main/queue_services/business-filer/pyproject.toml | grep -E '^version' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')</li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>queue_services/business-pay</strong>"
echo "    <ul>"
echo "      <li>$(curl -fsSL https://raw.githubusercontent.com/bcgov/lear/refs/heads/main/queue_services/business-pay/pyproject.toml | grep -E '^version' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')</li>"
echo "    </ul>"
echo "  </li>"
echo "</ul>"
echo "<hr>"

# Repo CD — static map of each component to its CD workflow on GitHub.
echo "<!-- repo cd -->"
echo "<h2>"
echo "Repo CD"
echo "</h2>"
echo "<ul>"
echo "  <li><strong>business-edit-ui</strong>"
echo "    <ul>"
echo "      <li><a href=\"https://github.com/bcgov/business-edit-ui/actions/workflows/cd.yml\">https://github.com/bcgov/business-edit-ui/actions/workflows/cd.yml</a></li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>business-filings-ui</strong>"
echo "    <ul>"
echo "      <li><a href=\"https://github.com/bcgov/business-filings-ui/actions/workflows/cd.yml\">https://github.com/bcgov/business-filings-ui/actions/workflows/cd.yml</a></li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>business-create-ui</strong>"
echo "    <ul>"
echo "      <li><a href=\"https://github.com/bcgov/business-create-ui/actions/workflows/cd.yml\">https://github.com/bcgov/business-create-ui/actions/workflows/cd.yml</a></li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>business-dashboard-ui</strong>"
echo "    <ul>"
echo "      <li><a href=\"https://github.com/bcgov/business-dashboard-ui/actions/workflows/cd.yml\">https://github.com/bcgov/business-dashboard-ui/actions/workflows/cd.yml</a></li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>business-registry-dashboard</strong>"
echo "    <ul>"
echo "      <li><a href=\"https://github.com/bcgov/business-ui/actions/workflows/business-registry-ui-cd.yaml\">https://github.com/bcgov/business-ui/actions/workflows/business-registry-ui-cd.yaml</a></li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>legal-api</strong>"
echo "    <ul>"
echo "      <li><a href=\"https://github.com/bcgov/lear/actions/workflows/business-api-cd.yml\">https://github.com/bcgov/lear/actions/workflows/business-api-cd.yml</a></li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>queue_services/business-bn</strong>"
echo "    <ul>"
echo "      <li><a href=\"https://github.com/bcgov/lear/actions/workflows/business-bn-cd.yml\">https://github.com/bcgov/lear/actions/workflows/business-bn-cd.yml</a></li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>queue_services/business-digital-credentials</strong>"
echo "    <ul>"
echo "      <li><a href=\"https://github.com/bcgov/lear/actions/workflows/business-digital-credentials-cd.yml\">https://github.com/bcgov/lear/actions/workflows/business-digital-credentials-cd.yml</a></li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>queue_services/business-emailer</strong>"
echo "    <ul>"
echo "      <li><a href=\"https://github.com/bcgov/lear/actions/workflows/business-emailer-cd.yml\">https://github.com/bcgov/lear/actions/workflows/business-emailer-cd.yml</a></li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>queue_services/business-filer</strong>"
echo "    <ul>"
echo "      <li><a href=\"https://github.com/bcgov/lear/actions/workflows/business-filer-cd.yml\">https://github.com/bcgov/lear/actions/workflows/business-filer-cd.yml</a></li>"
echo "    </ul>"
echo "  </li>"
echo "  <li><strong>queue_services/business-pay</strong>"
echo "    <ul>"
echo "      <li><a href=\"https://github.com/bcgov/lear/actions/workflows/business-pay-cd.yml\">https://github.com/bcgov/lear/actions/workflows/business-pay-cd.yml</a></li>"
echo "    </ul>"
echo "  </li>"
echo "</ul>"
echo "<hr>"
