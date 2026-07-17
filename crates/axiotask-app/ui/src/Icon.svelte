<script>
  let { name, size = 14, label = null } = $props();

  const paths = {
    calendar: [
      "M8 2v4",
      "M16 2v4",
      "M3 10h18",
      "M5 4h14a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2Z",
    ],
    checkCircle: [
      "M21 12a9 9 0 1 1-5.3-8.2",
      "m9 12 2 2 4-5",
    ],
    chevronDown: ["m6 9 6 6 6-6"],
    chevronRight: ["m9 18 6-6-6-6"],
    circle: ["M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z"],
    externalLink: [
      "M15 3h6v6",
      "M10 14 21 3",
      "M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6",
    ],
    fileText: [
      "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8Z",
      "M14 2v6h6",
      "M16 13H8",
      "M16 17H8",
      "M10 9H8",
    ],
  };
</script>

<svg
  class="icon"
  width={size}
  height={size}
  viewBox="0 0 24 24"
  fill="none"
  stroke="currentColor"
  stroke-width="2"
  stroke-linecap="round"
  stroke-linejoin="round"
  aria-hidden={label ? undefined : "true"}
  aria-label={label}
  role={label ? "img" : undefined}
>
  {#each paths[name] || paths.circle as d}
    <path {d}></path>
  {/each}
</svg>

<style>
  .icon {
    display: inline-block;
    flex-shrink: 0;
    vertical-align: -0.15em;
  }
</style>
