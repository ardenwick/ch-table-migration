
# tag > branch > commit
function git_describe_current()
{
    git describe --tags --exact-match 2> /dev/null \
        || git symbolic-ref -q --short HEAD \
        || git rev-parse --short HEAD
}

function git_short_sha() { git log --format=%h -1; }

function git_incremental_version_from_latest_tag()
{
    local latest_tag=$(git describe --tags --abbrev=0)
    local commits_since_tag=$(git rev-list ${latest_tag}..HEAD --count)

    local minor_version=$(echo $latest_tag | rev | cut -d. -f1 | rev)

    if [[ "$minor_version" =~ [0-9]+ ]]; then
        minor_version=$((minor_version + commits_since_tag))
        local version=${latest_tag%.*}.${minor_version}
        echo $version
    fi
}

version="$(git_incremental_version_from_latest_tag)-$(git_short_sha)"

echo "Current version string: $version"

make_package()
{(
    cd ..
    tar -zcf ch-table-migration_$version.tar.gz \
        ch-table-migration/README.md \
        ch-table-migration/ch-raw-copier \
        ch-table-migration/ch-table-migration \
        ch-table-migration/for_each_line2.sh \
        ch-table-migration/assets \
        ch-table-migration/docs
    # rm -rf ch-table-migration_*.tar.gz
)}

make_package
