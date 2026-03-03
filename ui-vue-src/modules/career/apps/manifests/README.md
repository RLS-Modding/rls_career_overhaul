Phone app manifests are auto-discovered by `phoneAppRegistry.js`.

To add a new app without editing `PhoneHomescreen.vue`:

1. Create a new file in this folder, e.g. `my-app.js`.
2. Export a default manifest object:

```js
import { icons } from '@/common/components/base'

export default {
  id: 'my-app',
  name: 'My App',
  // Option A: built-in vector icon
  icon: icons.cars,
  // Option B: custom image icon (full tile art) from `tiles/`
  // iconTile: 'my-app.png',
  // Option C: fully custom image path/URL
  // iconImage: '/local/ui/ui-vue/some/path/my-app.png',
  // iconImageFit: 'cover', // optional: 'cover' (default) | 'contain'
  // iconImageOverlay: false, // optional: adds default dark gradient when true
  route: '/career/phone-my-app',
  color: '#3366ff',
  iconColor: '#ffffff',
  category: 'Tools',
  defaultPage: 0,
  defaultPosition: 9,
  // Optional:
  // defaultDock: 0..3,
  // unlockCondition: async (luaBridge) => true/false
}
```

Custom icon example:

```js
import myIconPng from '../images/my-app.png'

export default {
  id: 'my-app',
  name: 'My App',
  iconImage: myIconPng,
  iconImageFit: 'cover',
  route: '/career/phone-my-app',
  color: '#222222',
}
```

Tile filename convention (recommended):

```js
export default {
  id: 'my-app',
  name: 'My App',
  iconTile: 'my-app.png', // resolved to /ui/entrypoints/main/tiles/my-app.png
  route: '/career/phone-my-app',
}
```

Place tile files in:

`ui/entrypoints/main/tiles/`

Note: You still need a matching route/view for `route`.
