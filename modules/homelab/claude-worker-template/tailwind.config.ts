// NOTE: Tailwind v4 ignores most of this file — configuration is CSS-based.
// To add plugins, use @plugin directives in src/app.css instead:
//   @plugin "@tailwindcss/forms";
//   @plugin "@tailwindcss/typography";
// Modifying the content array or plugins array below has no effect under v4.
import type { Config } from 'tailwindcss';

export default {
  content: ['./src/**/*.{html,js,svelte,ts}'],
  theme: {
    extend: {}
  },
  plugins: []
} satisfies Config;
