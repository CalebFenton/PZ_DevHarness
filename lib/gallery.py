"""Shows a Workshop item's gallery, or replaces its images with a folder's (docs/workshop-page.md).

    python3 gallery.py --lib <libsteam_api.dylib> --item <published file id> [--upload <folder>]

bin/workshop-gallery.sh runs it with what the mod's dev/harness.conf says. Without --upload it
lists the gallery. With it, the gallery's images become the folder's .jpg and .png files in name
order; its videos stay, before them. Only the gallery changes: an update that sets nothing else
leaves the title, description, tags and files alone. The game's own uploader can't do this
(SteamWorkshop.SubmitWorkshopItem never adds previews), so this talks to Steam through the game's
copy of the Steamworks library, as the game does: Steam must be running, logged in to the
account that owns the item.
"""
import argparse
import ctypes as C
import os
import sys
import tempfile
import time

APP_ID = 108600
# ISteamUGC::AddItemPreviewFile takes images under 1 MB.
IMAGE_BYTES = 1_000_000
# EItemPreviewType
IMAGE, YOUTUBE = 0, 1
# k_iSteamUGCCallbacks + 1 and + 4 (isteamugc.h).
QUERY_COMPLETED, SUBMIT_RESULT = 3401, 3404
RESULT_OK = 1
WAIT_SECONDS = 600


class QueryCompleted(C.Structure):
    # Steam packs callback structs to 4 bytes on macOS and Linux (steamclientpublic.h).
    _pack_ = 4
    _layout_ = "ms"
    _fields_ = [("handle", C.c_uint64), ("result", C.c_int), ("returned", C.c_uint32),
                ("total", C.c_uint32), ("cached", C.c_bool), ("cursor", C.c_char * 256)]


class SubmitResult(C.Structure):
    _pack_ = 4
    _layout_ = "ms"
    _fields_ = [("result", C.c_int), ("needs_agreement", C.c_bool), ("item", C.c_uint64)]


class Steam:
    def __init__(self, lib):
        # SteamAPI_InitFlat reads the app id from steam_appid.txt in the working directory.
        os.chdir(tempfile.mkdtemp())
        with open("steam_appid.txt", "w") as f:
            f.write(str(APP_ID))
        api = self.api = C.CDLL(lib)
        error = C.create_string_buffer(1024)
        if api.SteamAPI_InitFlat(error) != 0:
            sys.exit(f"gallery: Steam didn't start the API ({error.value.decode()}); is Steam running?")
        # The interface's version is the library's, so take whichever it has.
        ugc = next(getattr(api, name) for name in (f"SteamAPI_SteamUGC_v{n:03d}" for n in range(40, 9, -1))
                   if hasattr(api, name))
        ugc.restype = C.c_void_p
        api.SteamAPI_SteamUtils_v010.restype = C.c_void_p
        self.ugc = C.c_void_p(ugc())
        self.utils = C.c_void_p(api.SteamAPI_SteamUtils_v010())
        for name, restype, argtypes in [
            ("ISteamUGC_CreateQueryUGCDetailsRequest", C.c_uint64, [C.POINTER(C.c_uint64), C.c_uint32]),
            ("ISteamUGC_SetReturnAdditionalPreviews", C.c_bool, [C.c_uint64, C.c_bool]),
            ("ISteamUGC_SendQueryUGCRequest", C.c_uint64, [C.c_uint64]),
            ("ISteamUGC_GetQueryUGCNumAdditionalPreviews", C.c_uint32, [C.c_uint64, C.c_uint32]),
            ("ISteamUGC_GetQueryUGCAdditionalPreview", C.c_bool,
             [C.c_uint64, C.c_uint32, C.c_uint32, C.c_char_p, C.c_uint32, C.c_char_p, C.c_uint32,
              C.POINTER(C.c_int)]),
            ("ISteamUGC_ReleaseQueryUGCRequest", C.c_bool, [C.c_uint64]),
            ("ISteamUGC_StartItemUpdate", C.c_uint64, [C.c_uint32, C.c_uint64]),
            ("ISteamUGC_AddItemPreviewFile", C.c_bool, [C.c_uint64, C.c_char_p, C.c_int]),
            ("ISteamUGC_RemoveItemPreview", C.c_bool, [C.c_uint64, C.c_uint32]),
            ("ISteamUGC_SubmitItemUpdate", C.c_uint64, [C.c_uint64, C.c_char_p]),
        ]:
            function = getattr(api, "SteamAPI_" + name)
            function.restype = restype
            function.argtypes = [C.c_void_p] + argtypes
        api.SteamAPI_ISteamUtils_IsAPICallCompleted.restype = C.c_bool
        api.SteamAPI_ISteamUtils_IsAPICallCompleted.argtypes = [C.c_void_p, C.c_uint64, C.POINTER(C.c_bool)]
        api.SteamAPI_ISteamUtils_GetAPICallResult.restype = C.c_bool
        api.SteamAPI_ISteamUtils_GetAPICallResult.argtypes = [C.c_void_p, C.c_uint64, C.c_void_p, C.c_int,
                                                              C.c_int, C.POINTER(C.c_bool)]

    def ugc_call(self, name, *args):
        return getattr(self.api, "SteamAPI_ISteamUGC_" + name)(self.ugc, *args)

    def wait(self, call, result, callback):
        failed = C.c_bool()
        deadline = time.time() + WAIT_SECONDS
        while not self.api.SteamAPI_ISteamUtils_IsAPICallCompleted(self.utils, call, C.byref(failed)):
            if time.time() > deadline:
                sys.exit("gallery: Steam didn't answer")
            self.api.SteamAPI_RunCallbacks()
            time.sleep(0.1)
        if not self.api.SteamAPI_ISteamUtils_GetAPICallResult(
                self.utils, call, C.byref(result), C.sizeof(result), callback, C.byref(failed)) or failed.value:
            sys.exit("gallery: Steam's answer was lost")
        return result

    def previews(self, item):
        """The item's gallery, in order, as (type, file name or video id, URL)."""
        ids = (C.c_uint64 * 1)(item)
        query = self.ugc_call("CreateQueryUGCDetailsRequest", ids, 1)
        self.ugc_call("SetReturnAdditionalPreviews", query, True)
        done = self.wait(self.ugc_call("SendQueryUGCRequest", query), QueryCompleted(), QUERY_COMPLETED)
        if done.result != RESULT_OK or done.returned != 1:
            sys.exit(f"gallery: Steam has no item {item} (EResult {done.result})")
        found = []
        for index in range(self.ugc_call("GetQueryUGCNumAdditionalPreviews", query, 0)):
            url, name, kind = C.create_string_buffer(2048), C.create_string_buffer(1024), C.c_int()
            self.ugc_call("GetQueryUGCAdditionalPreview", query, 0, index, url, 2048, name, 1024, C.byref(kind))
            found.append((kind.value, (name.value or url.value).decode(), url.value.decode()))
        self.ugc_call("ReleaseQueryUGCRequest", query)
        return found

    def replace_images(self, item, current, files):
        update = self.ugc_call("StartItemUpdate", APP_ID, item)
        # Indices shift as previews go, so the last goes first.
        for index in reversed(range(len(current))):
            if current[index][0] != YOUTUBE and not self.ugc_call("RemoveItemPreview", update, index):
                sys.exit(f"gallery: Steam refused to remove preview {index}")
        for path in files:
            if not self.ugc_call("AddItemPreviewFile", update, path.encode(), IMAGE):
                sys.exit(f"gallery: Steam refused {path}")
        done = self.wait(self.ugc_call("SubmitItemUpdate", update, None), SubmitResult(), SUBMIT_RESULT)
        if done.needs_agreement:
            print("gallery: accept the Workshop legal agreement on Steam before the item can show", file=sys.stderr)
        if done.result != RESULT_OK:
            sys.exit(f"gallery: Steam refused the update (EResult {done.result})")


def gallery_files(folder):
    files = sorted(os.path.join(folder, name) for name in os.listdir(folder)
                   if name.lower().endswith((".jpg", ".jpeg", ".png")))
    if not files:
        sys.exit(f"gallery: no images in {folder}")
    for path in files:
        if os.path.getsize(path) >= IMAGE_BYTES:
            sys.exit(f"gallery: {path} is {os.path.getsize(path)} bytes; Steam takes under {IMAGE_BYTES}")
    return files


def show(previews):
    for kind, name, url in previews:
        print(f"  {'video' if kind == YOUTUBE else 'image'} {name}" + (f"  {url}" if kind != YOUTUBE else ""))
    if not previews:
        print("  (empty)")


def main(argv):
    parser = argparse.ArgumentParser(usage=__doc__.split("\n\n")[1])
    parser.add_argument("--lib", required=True)
    parser.add_argument("--item", type=int, required=True)
    parser.add_argument("--upload")
    args = parser.parse_args(argv)

    files = gallery_files(os.path.abspath(args.upload)) if args.upload else []
    steam = Steam(args.lib)
    current = steam.previews(args.item)
    print(f"Workshop item {args.item}'s gallery:")
    show(current)
    if files:
        steam.replace_images(args.item, current, files)
        print("now:")
        show(steam.previews(args.item))
    steam.api.SteamAPI_Shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
