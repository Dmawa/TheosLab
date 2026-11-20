#!/usr/bin/env python3
#
# export-toolchain.py
# Ain
#
# Created by Ain on 2026/11/20.
#

"""Copy a stopped Theos Lab provisioning guest into a distributable fakefs image."""
import argparse
import shutil
import sqlite3
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("root", type=Path, help="stopped fakefs root that contains data and meta.db")
parser.add_argument("destination", type=Path, help="new output directory")
args = parser.parse_args()
root = args.root.resolve()
target = args.destination.resolve()
if target == root or root in target.parents:
    parser.error("destination must be outside the provisioning guest")
if not (root / "data/opt/.theoslab-ready").is_file():
    parser.error("guest provisioning did not complete")
tools = (
    "usr/bin/make", "usr/bin/clang", "usr/bin/ld64.lld", "usr/bin/perl",
    "usr/bin/zip", "usr/bin/dpkg-deb", "usr/local/bin/ldid",
    "opt/theos/makefiles/common.mk", "opt/theos/vendor/logos/bin/logos.pl",
)
for path in tools:
    if not (root / "data" / path).is_file():
        parser.error("provisioning guest is missing " + path)

drop_contents = (
    b"/opt/theos/sdks", b"/root", b"/tmp", b"/var/cache",
    b"/var/log", b"/run", b"/mnt", b"/home",
)
drop_items = (b"/opt/theos/lib/Practice.dylib",)

def excluded(path):
    return (path in drop_items
            or any(path.startswith(prefix + b"/") for prefix in drop_contents)
            or (path.startswith(b"/opt/theos/") and b".git" in path.split(b"/")))

def ignore(folder, names):
    relative = Path(folder).relative_to(root / "data")
    prefix = b"" if relative == Path(".") else b"/" + str(relative).encode()
    return [name for name in names if excluded(prefix + b"/" + name.encode())]

if target.exists():
    parser.error("output directory already exists")
target.mkdir(parents=True)
try:
    shutil.copytree(root / "data", target / "data", symlinks=True, ignore=ignore)
    # The bundled vendor files have no Git metadata. Check for their licenses.
    rules = target / "data/opt/theos/makefiles/master/rules.mk"
    contents = rules.read_text()
    previous = "$(THEOS_VENDOR_INCLUDE_PATH)/.git)$(call __exists,$(THEOS_VENDOR_LIBRARY_PATH)/.git)"
    installed = "$(THEOS_VENDOR_INCLUDE_PATH)/LICENSE.md)$(call __exists,$(THEOS_VENDOR_LIBRARY_PATH)/LICENSE.md)"
    if previous not in contents:
        raise ValueError("Unexpected Theos vendor validation rule")
    rules.write_text(contents.replace(previous, installed))
    source = sqlite3.connect((root / "meta.db").as_uri() + "?mode=ro", uri=True)
    destination = sqlite3.connect(target / "meta.db")
    try:
        source.backup(destination)
        paths = destination.execute("SELECT path FROM paths").fetchall()
        destination.executemany("DELETE FROM paths WHERE path = ?",
                                [(path,) for (path,) in paths if excluded(path)])
        destination.execute("DELETE FROM stats WHERE inode NOT IN (SELECT inode FROM paths)")
        destination.commit()
        destination.execute("VACUUM")
        destination.execute("PRAGMA journal_mode=DELETE")
        assert destination.execute("PRAGMA integrity_check").fetchone() == ("ok",)
    finally:
        source.close()
        destination.close()
except BaseException:
    shutil.rmtree(target)
    raise
