#!/usr/bin/env python3
"""Recover the member avatars from the 2016 web backup.

The web backup holds the avatar store of the forum: 779 files for 390
members, under images/avatars/upload/.

The file name is the phpBB avatar name, `<salt>_<user_id>.<extension>`.
The salt is the one in the board's own config, so the files can be
used as they are. phpBB stores the name in phpbb_users.user_avatar
and the type in user_avatar_type, and the width and the height are
read from the file itself.

The members whose user row was destroyed lost their avatar with it,
so the file is in the backup but the row does not point at it. The
files are put back and the rows are set to point at them.

The width and the height are read from the file, because phpBB shows
the avatar at the size it was uploaded. The dimensions are not
resized: the image is shown as it was.

Usage:
    python3 recover-avatars.py [database] [--dry-run]
"""
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile

CONTAINER = os.environ.get("MARIADB_CONTAINER", "phpbb-mariadb")
ROOT_PASS = os.environ.get("MARIADB_ROOT_PASSWORD", "root_secret_password")
DB_NAME = os.environ.get("PHPBB_DB_NAME", "phpbb")

# The container the forum runs in. The avatar store is a volume on it.
APP_CONTAINER = os.environ.get("PHPBB_APP_CONTAINER", "phpbb-app")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB_BACKUP = os.path.join(REPO_ROOT,
                           "backup_recover/phpbb_web_backup.tar.gz")

# The avatar store inside the web backup.
AVATAR_PATH_IN_BACKUP = "images/avatars/upload"

# The container path of the avatar store.
AVATAR_PATH_IN_CONTAINER = "/var/www/html/images/avatars/upload"

# The avatar types phpBB knows.
UPLOAD = "avatar.driver.upload"
GALLERY = "avatar.example.com"


def log(message):
    print("  " + message)


def db(query):
    """Run a query and return the rows."""
    result = subprocess.run(
        ["docker", "exec", CONTAINER, "mariadb", "-uroot",
         "-p" + ROOT_PASS, "-N", "-e", query],
        capture_output=True, text=True)
    if result.returncode != 0:
        return []
    return [line for line in result.stdout.splitlines() if line]


def image_size(data):
    """The width and the height of an image, or null if it is not one.

    The size is read from the file itself, so the avatar is shown at
    the size it was uploaded. Only the formats phpBB accepts are
    read: JPEG, PNG and GIF.
    """
    # the PNG header
    if data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR':
        width, height = struct.unpack('>II', data[16:24])
        return width, height

    # the GIF header
    if data[:6] in (b'GIF87a', b'GIF89a'):
        width, height = struct.unpack('<HH', data[6:10])
        return width, height

    # the JPEG header: walk the segments to the start of the image
    if data[:2] == b'\xff\xd8':
        index = 2
        while index < len(data) - 9:
            if data[index] != 0xFF:
                index += 1
                continue
            marker = data[index + 1]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                          0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                height, width = struct.unpack('>HH', data[index + 5:index + 9])
                return width, height
            length = struct.unpack('>H', data[index + 2:index + 4])[0]
            index += 2 + length
        return None

    return None


def main():
    global DB_NAME
    dry_run = "--dry-run" in sys.argv
    arguments = [a for a in sys.argv[1:] if not a.startswith("--")]
    if arguments:
        DB_NAME = arguments[0]

    if not os.path.exists(WEB_BACKUP):
        log("the web backup is missing: %s" % WEB_BACKUP)
        return 1

    # the salt of the board, which is the prefix of the file names
    salt = ""
    for row in db("SELECT config_value FROM %s.phpbb_config "
                  "WHERE config_name = 'avatar_salt';" % DB_NAME):
        salt = row.strip()
    if not salt:
        log("the board has no avatar salt, so the file names cannot be read")
        return 1
    log("the avatar salt: %s" % salt)

    # the avatar files in the web backup
    prefix = salt + "_"
    files = {}
    with tarfile.open(WEB_BACKUP, "r:gz") as tar:
        for member in tar:
            if not member.isfile():
                continue
            if "/%s/" % AVATAR_PATH_IN_BACKUP not in member.name:
                continue
            name = member.name.split("/")[-1]
            if not name.startswith(prefix):
                continue
            rest = name[len(prefix):]
            if "." not in rest:
                continue
            user_id, extension = rest.rsplit(".", 1)
            if not user_id.isdigit():
                continue
            files.setdefault(user_id, []).append((name, extension, member))

    log("the avatar files in the backup: %d for %d members"
        % (sum(len(v) for v in files.values()), len(files)))

    # The avatar files are also written to the backup directory, so
    # the backup holds them and not only the web backup they came
    # from. The web backup is the only copy, so the files are worth
    # having in one place.
    avatar_dir = os.path.join(REPO_ROOT, "backup_recover", "avatars")
    if not dry_run:
        os.makedirs(avatar_dir, exist_ok=True)
        with tarfile.open(WEB_BACKUP, "r:gz") as tar:
            for user_id, candidates in files.items():
                for name, extension, member in candidates:
                    target = os.path.join(avatar_dir, name)
                    if os.path.exists(target):
                        continue
                    data = tar.extractfile(member).read()
                    with open(target, "wb") as f:
                        f.write(data)
        saved = len(os.listdir(avatar_dir))
        log("the avatar files in the backup directory: %d" % saved)

    # the members
    members = {}
    for row in db("SELECT CONCAT(user_id, '|', username, '|', user_avatar) "
                  "FROM %s.phpbb_users WHERE user_type IN (0, 1);" % DB_NAME):
        parts = row.split("|")
        if len(parts) >= 3 and parts[0].isdigit():
            members[parts[0]] = (parts[1], parts[2])

    log("the members: %d" % len(members))

    # the members that get their avatar back
    #
    # A member whose user row was destroyed lost the avatar with it,
    # so the file is in the backup but the row does not point at it.
    # A member whose row survived keeps the name of the avatar it
    # had, but the file is not in the board, so the name is used as
    # it is and the file is put back under it.
    targets = []
    for user_id, candidates in sorted(files.items(), key=lambda x: int(x[0])):
        if user_id not in members:
            continue

        # the largest file is the one the board used last, because
        # phpBB overwrites the file when a member uploads a new one
        candidates.sort(key=lambda c: c[2].size)
        name, extension, member = candidates[-1]

        if members[user_id][1]:
            # the member already has an avatar, so only the file is
            # missing
            stored = members[user_id][1]
            stored_extension = stored.rsplit('.', 1)[-1].lower() \
                if '.' in stored else extension
            targets.append((user_id, members[user_id][0], name,
                            stored_extension, member, stored))
            continue

        stored = "%s_%d.%s" % (user_id, int(member.mtime), extension)
        targets.append((user_id, members[user_id][0], name, extension,
                        member, stored))

    log("the members that get their avatar back: %d" % len(targets))

    if dry_run:
        for user_id, username, name, extension, member in targets[:10]:
            log("  %-7s %-20s -> %s" % (user_id, username, name))
        log("this was a dry run, nothing was changed")
        return 0

    # the files are put back in the container, and the rows are set
    # to point at them
    extracted = 0
    set_rows = 0
    unreadable = 0

    with tempfile.TemporaryDirectory() as work:
        for user_id, username, name, extension, member, stored_name in targets:
            tar = tarfile.open(WEB_BACKUP, "r:gz")
            data = tar.extractfile(member).read()
            tar.close()

            size = image_size(data)
            if size is None:
                unreadable += 1
                continue
            width, height = size

            # The file on disk is named `<salt>_<user_id>.<ext>`. The
            # name in the row is the one phpBB 3.3 writes, which is
            # the user id and the time the avatar was uploaded,
            # without the salt. phpBB adds the salt when it serves the
            # file, and it reads the user id out of the name.
            disk_name = name

            # the file is written to the container
            local = os.path.join(work, disk_name)
            with open(local, "wb") as f:
                f.write(data)
            copied = subprocess.run(
                ["docker", "cp", local,
                 "%s:%s/%s" % (APP_CONTAINER, AVATAR_PATH_IN_CONTAINER, disk_name)],
                capture_output=True, text=True)
            if copied.returncode != 0:
                log("the copy of %s failed: %s" % (disk_name, copied.stderr.strip()))
                continue
            extracted += 1

            # the row points at the file
            db("UPDATE %s.phpbb_users SET user_avatar = '%s', "
               "user_avatar_type = '%s', user_avatar_width = %d, "
               "user_avatar_height = %d WHERE user_id = %s;"
               % (DB_NAME, stored_name, UPLOAD, width, height, user_id))
            set_rows += 1

    log("the avatar files copied into the board: %d" % extracted)
    log("the member rows set to point at them: %d" % set_rows)
    if unreadable:
        log("the files that are not a readable image: %d" % unreadable)

    # The files are copied as root, but the forum runs as an ordinary
    # user, so the owner is set to the user of the forum. The forum
    # container cannot do it itself, because it is not root, so a
    # short lived container is used for the volume.
    if extracted:
        volume = ""
        mounts = subprocess.run(
            ["docker", "inspect", APP_CONTAINER, "--format",
             "{{range .Mounts}}{{.Name}} {{.Destination}}{{\"\\n\"}}{{end}}"],
            capture_output=True, text=True).stdout
        for line in mounts.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[1] == AVATAR_PATH_IN_CONTAINER:
                volume = parts[0]
                break
        if volume:
            subprocess.run(
                ["docker", "run", "--rm", "-v", "%s:%s" % (volume, AVATAR_PATH_IN_CONTAINER),
                 "alpine", "sh", "-c",
                 "chown 1000:1000 %s/* 2>/dev/null; true" % AVATAR_PATH_IN_CONTAINER],
                capture_output=True)
            log("the owner of the avatar files set to the forum user")
        else:
            log("the avatar volume was not found, so the owner was not set")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
