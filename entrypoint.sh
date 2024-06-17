#!/bin/bash -l

set -o errexit -o pipefail -o nounset

REPOSITORY=$INPUT_REPOSITORY
GPG_PRIVATE_KEY="$INPUT_GPG_PRIVATE_KEY"
GPG_PASSPHRASE=$INPUT_GPG_PASSPHRASE
TARBALL=$INPUT_TARBALL
DEBIAN_DIR=$INPUT_DEBIAN_DIR
SERIES=$INPUT_SERIES
REVISION=$INPUT_REVISION
DEB_EMAIL=$INPUT_DEB_EMAIL
DEB_FULLNAME=$INPUT_DEB_FULLNAME
# Extra ppa separated by space
EXTRA_PPA=$INPUT_EXTRA_PPA

assert_non_empty() {
    name=$1
    value=$2
    if [[ -z "$value" ]]; then
        echo "::error::Invalid Value: $name is empty." >&2
        exit 1
    fi
}

assert_non_empty inputs.repository "$REPOSITORY"
assert_non_empty inputs.gpg_private_key "$GPG_PRIVATE_KEY"
assert_non_empty inputs.gpg_passphrase "$GPG_PASSPHRASE"
# assert_non_empty inputs.tarball "$TARBALL"
assert_non_empty inputs.deb_email "$DEB_EMAIL"
assert_non_empty inputs.deb_fullname "$DEB_FULLNAME"

export DEBEMAIL="$DEB_EMAIL"
export DEBFULLNAME="$DEB_FULLNAME"

echo "::group::Importing GPG private key..."
echo "Importing GPG private key..."

GPG_KEY_ID=$(echo "$GPG_PRIVATE_KEY" | gpg --import-options show-only --import | sed -n '2s/^\s*//p')
echo $GPG_KEY_ID
echo "$GPG_PRIVATE_KEY" | gpg --batch --passphrase "$GPG_PASSPHRASE" --import

echo "Checking GPG expirations..."
if [[ $(gpg --list-keys | grep expired) ]]; then
    echo "GPG key has expired. Please update your GPG key." >&2
    exit 1
fi

echo "::endgroup::"

echo "::group::Adding PPA..."
echo "Adding PPA: $REPOSITORY"
add-apt-repository -y ppa:$REPOSITORY
# Add extra PPA if it's been set
if [[ -n "$EXTRA_PPA" ]]; then
    for ppa in $EXTRA_PPA; do
        echo "Adding PPA: $ppa"
        add-apt-repository -y ppa:$ppa
    done
fi
apt-get update
echo "::endgroup::"

if [[ -z "$SERIES" ]]; then
    SERIES=$(distro-info --supported)
fi

# Add extra series if it's been set
if [[ -n "$INPUT_EXTRA_SERIES" ]]; then
    SERIES="$INPUT_EXTRA_SERIES $SERIES"
fi

rm -rf /tmp/workspace
mkdir -p /tmp/workspace/{blueprint,build}

if [[ -s "${TARBALL}" ]]; then
    mkdir -p /tmp/workspace/blueprint/source
    cp -fv $TARBALL /tmp/workspace/blueprint/source
    cd /tmp/workspace/blueprint/source
    tar -xf *
fi

# Extract the package name from the original debian changelog
cd ${DEBIAN_DIR}/..
PACKAGE_NAME=$(dpkg-parsechangelog --show-field Source)
PACKAGE_VERSION=$(dpkg-parsechangelog --show-field Version | cut -d- -f1)
if [[ -n "${PACKAGE_NAME}" && -n "${PACKAGE_VERSION}" ]]; then
    mkdir -p "/tmp/workspace/blueprint/${PACKAGE_NAME}-${PACKAGE_VERSION}"
    rsync -a --delete-after --exclude=changelog ${DEBIAN_DIR}/ "/tmp/workspace/blueprint/${PACKAGE_NAME}-${PACKAGE_VERSION}/debian/"
else
    echo "No package name and version could be extracted from changelog." >&2
    exit 1
fi

cd "/tmp/workspace/blueprint/${PACKAGE_NAME}-${PACKAGE_VERSION}"

if [[ -s "${TARBALL}" ]]; then
    echo "Making non-native package..."
    debmake
else
    echo "Making native package..."
    debmake -n
fi

# Install build dependencies
mk-build-deps --install --remove --tool='apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends --yes' debian/control

rm -rf debian/changelog

changes="New upstream release"


for s in $SERIES; do
    ubuntu_version=$(distro-info --series $s -r | cut -d' ' -f1)

    echo "::group::Building deb for: $ubuntu_version ($s)"
    
    rsync -a /tmp/workspace/blueprint/ /tmp/workspace/build/$s/
    cd "/tmp/workspace/build/$s/${PACKAGE_NAME}-${PACKAGE_VERSION}"

    # Create new debian changelog
    dch --create --distribution $s --package $PACKAGE_NAME --newversion $PACKAGE_VERSION-ppa$REVISION~ubuntu$ubuntu_version "$changes"

    debuild -S -sa \
        -k"$GPG_KEY_ID" \
        -p"gpg --batch --passphrase "$GPG_PASSPHRASE" --pinentry-mode loopback"

    dput ppa:$REPOSITORY ../*.changes

    echo "::endgroup::"
done
