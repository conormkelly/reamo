/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
    "./pages/**/*.{js,ts,jsx,tsx,html}",
  ],
  theme: {
    extend: {
      animation: {
        'spin-slow': 'spin 4s linear infinite',
      },
      // Semantic z-index scale (UX_GUIDELINES.md §5)
      zIndex: {
        'base': '0',
        'elevated': '10',
        'dropdown': '100',
        'sticky': '200',
        'fixed': '300',
        'modal-backdrop': '400',
        'modal': '500',
        'popover': '600',
        'toast': '700',
        'tooltip': '800',
      },
    },
  },
  plugins: [],
}
