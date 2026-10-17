import { defineConfig } from 'vite';
import { VitePWA } from 'vite-plugin-pwa';

export default defineConfig({
  base: './',
  plugins: [
    VitePWA({
      registerType: 'autoUpdate',
      workbox: { maximumFileSizeToCacheInBytes: 10 * 1024 * 1024 },
      manifest: {
        name: 'MDobe',
        short_name: 'MDobe',
        description: 'Visor y editor de PDF',
        theme_color: '#b3261e',
        background_color: '#1e1e1e',
        display: 'standalone',
        icons: [{ src: 'icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any maskable' }],
        // Permite elegir MDobe como app para abrir PDFs (Chrome/Edge en Mac y Android)
        file_handlers: [{ action: './', accept: { 'application/pdf': ['.pdf'] } }],
      } as any,
    }),
  ],
});
