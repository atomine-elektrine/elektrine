// Tailwind CSS v4 configuration
// https://tailwindcss.com/docs/configuration

import plugin from "tailwindcss/plugin"
import fs from "fs"
import path from "path"
import { fileURLToPath } from 'url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

function resolveHeroiconsDir() {
  const candidates = [
    // Umbrella app layout: apps/elektrine/assets -> ../../../deps
    path.join(__dirname, "../../../deps/heroicons/optimized"),
    // Non-umbrella fallback: assets -> ../deps
    path.join(__dirname, "../deps/heroicons/optimized")
  ]

  const existing = candidates.find((candidate) => fs.existsSync(candidate))
  if (!existing) {
    throw new Error(`Heroicons directory not found. Checked: ${candidates.join(", ")}`)
  }

  return existing
}

export default {
  content: [
    "./js/**/*.js",
    "../lib/elektrine_web.ex",
    "../lib/elektrine_web/**/*.*ex"
  ],
  theme: {
    extend: {
      colors: {
        brand: "#FD4F00",
      },
      fontFamily: {
        sans: ['Inter', 'ui-sans-serif', 'system-ui', '-apple-system', 'sans-serif'],
      }
    },
  },
  plugins: [
    // LiveView loading variants
    plugin(({addVariant}) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({addVariant}) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({addVariant}) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"])),

    // Heroicons plugin
    plugin(function({matchComponents, theme}) {
      let iconsDir = resolveHeroiconsDir()
      let values = {}
      let icons = [
        ["", "/24/outline"],
        ["-solid", "/24/solid"],
        ["-mini", "/20/solid"],
        ["-micro", "/16/solid"]
      ]
      icons.forEach(([suffix, dir]) => {
        fs.readdirSync(path.join(iconsDir, dir)).forEach(file => {
          let name = path.basename(file, ".svg") + suffix
          values[name] = {name, fullPath: path.join(iconsDir, dir, file)}
        })
      })
      matchComponents({
        "hero": ({name, fullPath}) => {
          let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
          let size = theme("spacing.6")
          if (name.endsWith("-mini")) {
            size = theme("spacing.5")
          } else if (name.endsWith("-micro")) {
            size = theme("spacing.4")
          }
          return {
            [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
            "-webkit-mask": `var(--hero-${name})`,
            "mask": `var(--hero-${name})`,
            "mask-repeat": "no-repeat",
            "background-color": "currentColor",
            "vertical-align": "middle",
            "display": "inline-block",
            "width": size,
            "height": size
          }
        }
      }, {values})
    })
  ]
}
