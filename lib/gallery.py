"""Shows a Workshop item's gallery, or replaces its images with a folder's (docs/workshop-page.md#the-gallery).

    gallery.py --item <published file id> [--upload <folder>]

bin/workshop-gallery.sh runs it with uv and Playwright. It works the item's Add/Edit Images &
Videos page as its owner would, in Google Chrome with a profile of its own that stays logged in
to Steam: the first run opens a window to log in, later runs are headless. With --upload, the
gallery's images become the folder's, sorted by name: an image whose name and content are already
there stays, and the rest go and come up again, since Steam refuses an upload it already has
(EResult 29). Videos are left alone. Only the gallery changes.

The page and not the Steamworks API: ISteamUGC::AddItemPreviewFile keeps each image in the
uploader's Steam Cloud space for the game, a megabyte shared by all of an account's Project
Zomboid items, and the images break when those copies are deleted. The page's uploads don't use
that space.
"""
import argparse
import hashlib
import os
import sys
import time
import urllib.request

from playwright.sync_api import sync_playwright

PROFILE = os.path.expanduser("~/.cache/pz-devharness/steam-browser")
MANAGE = "https://steamcommunity.com/sharedfiles/managepreviews/?id={}"
LOGIN = "https://steamcommunity.com/login/home/?goto=sharedfiles%2Fmanagepreviews%2F%3Fid%3D{}"
# The page's UploadPreviewFile refuses larger images, and it takes "up to 8 MB at once".
IMAGE_BYTES = 2 * 1024 * 1024
BATCH_BYTES = 8_000_000
LOGIN_SECONDS = 600
UPLOAD_MS = 300_000
# Steam can list a batch's last images some seconds after it answers the upload.
LISTED_SECONDS = 60

PREVIEWS = "gPreviewImages.map(p => ({id: p.previewid, name: p.filename, url: p.url}))"
REMOVE = """previewid => fetch('https://steamcommunity.com/sharedfiles/removepreview', {
    method: 'POST', body: new URLSearchParams({id: publishedfileid, sessionid: g_sessionID, previewid, ajax: 'true'})
}).then(response => response.json()).then(json => json.success)"""


def gallery_files(folder):
    files = sorted(os.path.join(folder, name) for name in os.listdir(folder)
                   if name.lower().endswith((".jpg", ".jpeg", ".png")))
    if not files:
        sys.exit(f"gallery: no images in {folder}")
    for path in files:
        if os.path.getsize(path) > IMAGE_BYTES:
            sys.exit(f"gallery: {path} is {os.path.getsize(path)} bytes; Steam takes at most {IMAGE_BYTES}")
    return files


def batches(files):
    batch, size = [], 0
    for path in files:
        if batch and size + os.path.getsize(path) > BATCH_BYTES:
            yield batch
            batch, size = [], 0
        batch.append(path)
        size += os.path.getsize(path)
    if batch:
        yield batch


def unchanged(preview, path):
    # An image's URL ends in the SHA-1 of its file.
    with open(path, "rb") as f:
        return preview["url"].rstrip("/").rsplit("/", 1)[-1].lower() == hashlib.sha1(f.read()).hexdigest()


class Gallery:
    def __init__(self, playwright, item):
        self.playwright, self.item = playwright, item
        self.context = self.launch(headless=True)
        self.page = self.context.pages[0]
        self.dialogs = []
        self.page.on("dialog", lambda dialog: (self.dialogs.append(dialog.message), dialog.dismiss()))
        self.page.goto(MANAGE.format(item))
        if not self.on_manager():
            self.log_in()

    def launch(self, headless):
        context = self.playwright.chromium.launch_persistent_context(
            PROFILE, channel="chrome", headless=headless, viewport={"width": 1280, "height": 900})
        if not context.pages:
            context.new_page()
        return context

    def on_manager(self):
        return self.page.url.startswith(MANAGE.format(self.item)) and \
            self.page.evaluate("typeof gPreviewImages == 'object' && !!g_steamID")

    def log_in(self):
        self.context.close()
        self.context = self.launch(headless=False)
        self.page = self.context.pages[0]
        self.page.on("dialog", lambda dialog: (self.dialogs.append(dialog.message), dialog.dismiss()))
        self.page.goto(LOGIN.format(self.item))
        print("gallery: log in to Steam in the Chrome window, as the item's owner; it stays logged in",
              file=sys.stderr)
        deadline = time.time() + LOGIN_SECONDS
        while not self.on_manager():
            if time.time() > deadline:
                sys.exit(f"gallery: Steam didn't show item {self.item}'s gallery page; "
                         "log in as the account that owns it")
            self.page.wait_for_timeout(1000)

    def previews(self):
        return self.page.evaluate(PREVIEWS)

    def reload(self):
        self.page.goto(MANAGE.format(self.item))
        if not self.on_manager():
            sys.exit("gallery: Steam stopped showing the gallery page")

    def remove(self, preview):
        if self.page.evaluate(REMOVE, preview["id"]) != 1:
            sys.exit(f"gallery: Steam refused to remove {preview['name']}")

    def upload(self, batch):
        self.dialogs.clear()
        self.page.set_input_files("#files", batch)
        self.page.evaluate("StartPreviewFileUpload()")
        # DoneFileUpload hides the throbber when Steam answers, then alerts if it failed.
        self.page.wait_for_function("$('PreviewFileUploadProgress').style.display == 'none'", timeout=UPLOAD_MS)
        self.page.wait_for_timeout(500)
        if self.dialogs:
            sys.exit(f"gallery: Steam refused the upload: {self.dialogs[0]}")
        names = {os.path.basename(path) for path in batch}
        deadline = time.time() + LISTED_SECONDS
        while missing := names - {p["name"] for p in self.previews()}:
            if time.time() > deadline:
                sys.exit(f"gallery: Steam didn't take {', '.join(sorted(missing))}")
            self.page.wait_for_timeout(2000)
            self.reload()

    def sort_by_name(self):
        with self.page.expect_response(lambda response: "setpreviewsortorder" in response.url) as answer:
            self.page.evaluate("SortPreviewImagesByFileName()")
        if answer.value.json().get("success") != 1:
            sys.exit("gallery: Steam refused the new order")

    def replace(self, files):
        wanted = {os.path.basename(path): path for path in files}
        for preview in self.previews():
            path = wanted.get(preview["name"])
            if path and unchanged(preview, path):
                del wanted[preview["name"]]
            else:
                self.remove(preview)
        for batch in batches(sorted(wanted.values())):
            self.upload(batch)
        self.reload()
        self.sort_by_name()
        self.reload()


def broken(previews):
    """The images Steam lists but doesn't serve."""
    found = []
    for preview in previews:
        try:
            urllib.request.urlopen(preview["url"], timeout=30).close()
        except OSError:
            found.append(preview["name"])
    return found


def show(previews):
    for preview in previews:
        print(f"  {preview['name']}  {preview['url']}")
    if not previews:
        print("  (no images)")


def main(argv):
    parser = argparse.ArgumentParser(usage=__doc__.split("\n\n")[1])
    parser.add_argument("--item", type=int, required=True)
    parser.add_argument("--upload")
    args = parser.parse_args(argv)

    files = gallery_files(os.path.abspath(args.upload)) if args.upload else []
    with sync_playwright() as playwright:
        gallery = Gallery(playwright, args.item)
        print(f"Workshop item {args.item}'s gallery images:")
        show(gallery.previews())
        if files:
            gallery.replace(files)
            print("now:")
            show(gallery.previews())
        previews = gallery.previews()
        gallery.context.close()
    bad = broken(previews)
    if bad:
        sys.exit(f"gallery: Steam lists {', '.join(bad)} but doesn't serve it")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
