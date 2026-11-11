<header class="header-container" class:fixed={isConstrainedHeader}>
  <img class="site-logo" src="/bresilla/logo.svg" alt="" />
  <Link ariaLabel="Radicle home" route={homeRoute()}>rad</Link>
  <div class="site-navigation">
    <slot name="breadcrumbs" />
  </div>

  {#if showSearch && !collapsedSearch}
    <div class="header-search">
      <RepoSearch baseUrl={$searchSeed} />
    </div>
  {/if}

  <div class="who">
    @CONTROLS@
  </div>
</header>
{#if isConstrainedHeader}
  <div class="header-spacer"></div>
{/if}
