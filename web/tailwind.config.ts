import type { Config } from 'tailwindcss';

export default {
  content: ['./index.html', './src/**/*.{svelte,ts}'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        // Dot palette — five filled steps from cool (easy) to hot (hard).
        // Used by DotsIndicator for both difficulty and entry barrier.
        dot: {
          1: '#22c55e', // green
          2: '#eab308', // yellow
          3: '#f97316', // orange
          4: '#ef4444', // red
          5: '#b91c1c', // deep red
          empty: '#3f3f46', // zinc-700 — unfilled
        },
      },
      fontFamily: {
        sans: ['-apple-system', 'BlinkMacSystemFont', 'Inter', 'system-ui', 'sans-serif'],
      },
    },
  },
  plugins: [],
} satisfies Config;
