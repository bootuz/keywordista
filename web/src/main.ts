import { mount } from 'svelte';
import App from './App.svelte';
import { initTheme } from './lib/theme';
import './app.css';

// Apply the saved theme class to <html> before the first paint so users
// don't see a flash of the wrong colour scheme on load.
initTheme();

const app = mount(App, {
  target: document.getElementById('app')!,
});

export default app;
