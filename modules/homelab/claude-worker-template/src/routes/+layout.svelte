<script lang="ts">
  import '../app.css';
  import type { Snippet } from 'svelte';
  let { children }: { children: Snippet } = $props();
</script>

<!-- Add site-wide navigation here if your app has multiple pages -->
<!-- Example: <nav class="p-4 border-b border-slate-800"><a href="/">Home</a></nav> -->

{@render children()}
