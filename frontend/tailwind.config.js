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
    },
  },
  plugins: [],
}
