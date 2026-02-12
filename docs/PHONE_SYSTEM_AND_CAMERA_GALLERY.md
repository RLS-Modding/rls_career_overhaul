# Phone System & Camera/Gallery Apps – Reference for Updates

This doc describes how the career phone works and how the **Camera** and **Gallery** apps plug in, so Camera/Gallery can be fixed after phone system changes.

---

## 1. Phone entry and lifecycle (Lua)

- **Extension:** `lua/ge/extensions/gameplay/phone.lua`
  - `gameplay_phone.togglePhone()` opens/closes the phone.
  - Open: `guihooks.trigger('ChangeState', { state = 'phone-main' })` (or `'phone-taxi'` if taxi job active).
  - Close: `guihooks.trigger('closePhone')`.
  - Phone closes when player moves (if not in cab); `isPhoneOpen` tracks state.
- **Input:** `lua/ge/extensions/core/input/actions/phone.json`  
  - Binds a key to load `gameplay_phone` and call `gameplay_phone.togglePhone()`.
- **Extension manager:** `lua/ge/extensions/overhaul/extensionManager.lua`
  - Sets `gameplay_phone` and `gameplay_phoneCamera` to manual unload; unloads them when leaving career.

---

## 2. Phone UI shell (Vue)

- **Wrapper (shared for all phone screens):** `ui-vue-src/modules/career/views/PhoneWrapper.vue`
  - **Props:** `appName`, `statusFontColor`, `statusBlendMode`, `scale`.
  - **Layout:** `.phone-wrapper` (fixed, bottom-right) → `.phone-screen` (360×640, rounded) → **status bar** (time + “<- Back” + app name) → **`.phone-content`** (slot for the app; has `padding-top: 2.8em` so content is below the status bar).
  - **Behavior:**
    - On mount: loads `ui_phone_time`, listens for `phone_time_update` and `closePhone`.
    - Uses `sessionStorage.getItem('phoneVisible')` to know if already on a phone route (no re-animate).
    - **Phone route check:** `routeName.startsWith('phone-') || routeName === 'car-meets-phone'`.
    - On leave to non-phone route: animates down, then `lua.career_career.closeAllMenus()` and unloads `ui_phone_time`.
    - Back button: `router.back()`.
  - **Important:** Any change to the phone “chrome” (status bar, content area, padding) will affect Camera and Gallery; they assume content starts below the status bar.

---

## 3. Routing and home screen

- **Routes:** `ui-vue-src/modules/career/routes.js`
  - Phone routes are **children of `/career`**:
    - `path: "phone-camera"`, `name: "phone-camera"`, `component: PhoneCamera`
    - `path: "phone-gallery"`, `name: "phone-gallery"`, `component: PhoneGallery`
  - Full paths: `/career/phone-camera`, `/career/phone-gallery`.
- **State → route:** The game triggers `ChangeState` with `state = 'phone-main'`. The app’s router (or state→route mapping elsewhere) must resolve that to the route that shows the phone home (and thus `/career/phone-camera` / `/career/phone-gallery` as sub-routes).
- **Home screen:** `ui-vue-src/modules/career/views/PhoneMain.vue`
  - Renders a grid of app buttons; Camera and Gallery are two of them:
    - Camera: `route: '/career/phone-camera'`
    - Gallery: `route: '/career/phone-gallery'`
  - Navigation is `router.push(app.route)`.

If you change route paths or names (e.g. rename `phone-camera` or move under a new parent), you must update:
- `routes.js` (path/name/component),
- `PhoneMain.vue` (app `route` for Camera and Gallery),
- Any logic that treats `phone-*` as “phone route” (e.g. `PhoneWrapper`’s `isPhoneRoute`).

---

## 4. Camera app (Vue + Lua)

### Vue: `ui-vue-src/modules/career/views/PhoneCamera.vue`

- **Structure:** Uses `<PhoneWrapper app-name="Camera" status-font-color="#FFFFFF" status-blend-mode="normal">` and puts full-screen viewfinder + top/bottom bars inside the default slot (no header slot).
- **Assumptions:**
  - It’s shown inside `PhoneWrapper`; the wrapper provides status bar and `.phone-content` (with top padding). The camera uses the rest of the content area (often full-bleed inside that area).
  - No direct dependency on route name; only that it’s mounted when the user navigates to the Camera app.
- **Lua usage:** All via `lua.gameplay_phoneCamera`:
  - `startPreview()`, `stopPreview()`, `setPreviewOrientation(orientation)` (on mount/unmount and when changing orientation).
  - `takePhoto(orientation)` when user taps capture.
- **Events:** Listens for `PhoneCameraPreviewFrame` (data URL string) to show the live preview image.
- **Services:** `@/services/events` for `events.on` / `events.off`.

If the phone system changes:
- Keep wrapping the camera UI in `PhoneWrapper` (or the new shared phone shell) with the same slot usage so the viewfinder still fills the content area.
- If the wrapper’s content area gets a new class or padding, adjust Camera’s layout so it doesn’t sit under the status bar or get clipped.

### Lua: `lua/ge/extensions/gameplay/phoneCamera.lua`

- **Role:** Implements `gameplay_phoneCamera`: take photo, list photos, get photo as data URL, delete photos, and live preview (periodic capture → `PhoneCameraPreviewFrame`).
- **Dependencies:** `ui_visibility`, `core_camera`, `render_renderViews`. Uses `career_career` and `career_saveSystem` only at runtime (no hard dependency) to choose photo directory when in career.
- **Photo paths:**
  - Freeroam: `screenshots/phone/`
  - Career: `{profileFolder}/Gallery/` (profile = parent of current autosave folder).
- **Exposed to UI:** `getPhotoList()`, `getPhotoAsDataUrl(filename)`, `deletePhotos(filenames)`, `takePhoto(orientation)`, `startPreview()`, `stopPreview()`, `setPreviewOrientation(orientation)`.
- **Extension loading:** Loaded by the mod with `gameplay_phone`; unloaded in extensionManager when leaving career. Camera app does not load/unload it; it’s expected to be loaded when the phone is available.

If the phone system changes:
- As long as the same Lua extension name and API are used, only the Vue side needs to keep calling `lua.gameplay_phoneCamera.*`. If you rename the extension or split APIs, update the Vue bridge and this file.

---

## 5. Gallery app (Vue only; Lua = phoneCamera)

### Vue: `ui-vue-src/modules/career/views/PhoneGallery.vue`

- **Structure:** Same as Camera: `<PhoneWrapper app-name="Gallery" ...>` and main content in the default slot (header with icon + title + Delete/Cancel, then grid or fullscreen image).
- **Assumptions:**
  - Same as Camera: shown inside the shared phone wrapper; content area already has top padding; no reliance on route name beyond being a phone route.
- **Lua usage:** All via `lua.gameplay_phoneCamera`:
  - `getPhotoList()` for the list of photos.
  - `getPhotoAsDataUrl(filename)` for thumbnails and fullscreen image.
  - `deletePhotos(filenames)` with an **array** of filenames (bridge must pass array; see bridge note below).
- **Components:** Uses `BngIcon`, `icons` from `@/common/components/base`.
- **No events:** Only Lua calls; no event subscriptions.

If the phone system changes:
- Same as Camera: keep using the shared wrapper (or new shell) so the gallery grid and fullscreen viewer sit in the content area; adjust layout if the wrapper’s content box or padding changes.

---

## 6. Lua bridge (signatures)

- **File:** `ui-vue-src/bridge/LuaFunctionSignatures.js`
- **Camera/Gallery-relevant block:** `gameplay_phoneCamera`
  - **Critical:** `deletePhotos` must take an **array** so the bridge doesn’t coerce it to a single value. Current signature: `deletePhotos: (filenames) => [Array]`.
  - Others: `getPhotoList`, `getPhotoAsDataUrl`, `takePhoto`, `startPreview`, `stopPreview`, `setPreviewOrientation` (as used by Camera/Gallery).

If you add or rename Lua APIs for the phone or camera, add/update the corresponding entries in this block and ensure array arguments use `[Array]` (or the correct type) so the bridge serializes them correctly.

---

## 7. Quick checklist when you change the phone system

- [ ] **Routes:** If phone routes move or rename, update `routes.js` and `PhoneMain.vue` (Camera/Gallery routes and any `isPhoneRoute`-style logic in `PhoneWrapper`).
- [ ] **PhoneWrapper / shell:** If you replace or heavily change the wrapper (status bar, content padding, class names), update **PhoneCamera.vue** and **PhoneGallery.vue** so their layout still fits (no content under status bar, correct scrolling if needed).
- [ ] **State/route mapping:** If `ChangeState` with `phone-main` (or equivalent) points to a different route, ensure Camera and Gallery remain reachable from the new home (e.g. same `/career/phone-camera` and `/career/phone-gallery` or update all references).
- [ ] **Lua:** If `gameplay_phone` or `gameplay_phoneCamera` is renamed or split, update extensionManager, phone.lua, and all Vue calls to `lua.gameplay_phoneCamera.*`; also update `LuaFunctionSignatures.js` for `gameplay_phoneCamera` (especially `deletePhotos: (filenames) => [Array]`).
- [ ] **Events:** If you change how the phone closes or how time is updated, ensure `closePhone` and `phone_time_update` (and any `PhoneCameraPreviewFrame`) still work; PhoneWrapper and PhoneCamera depend on them.
- [ ] **Rebuild UI:** After any change to Vue or `LuaFunctionSignatures.js`, rebuild the UI (e.g. `build_ui.bat`) so the game loads the updated bundle.

---

## 8. File list (Camera & Gallery)

| Role | Path |
|------|------|
| Phone wrapper (shared) | `ui-vue-src/modules/career/views/PhoneWrapper.vue` |
| Phone home (app grid) | `ui-vue-src/modules/career/views/PhoneMain.vue` |
| Routes | `ui-vue-src/modules/career/routes.js` |
| Camera (Vue) | `ui-vue-src/modules/career/views/PhoneCamera.vue` |
| Gallery (Vue) | `ui-vue-src/modules/career/views/PhoneGallery.vue` |
| Camera + Gallery (Lua) | `lua/ge/extensions/gameplay/phoneCamera.lua` |
| Phone toggle (Lua) | `lua/ge/extensions/gameplay/phone.lua` |
| Bridge signatures | `ui-vue-src/bridge/LuaFunctionSignatures.js` |
| Extension loading | `lua/ge/extensions/overhaul/extensionManager.lua` |
| Time on status bar | `lua/ge/extensions/ui/phone/time.lua` |

Use this when you update the phone so we can fix the Camera and Gallery apps consistently.
