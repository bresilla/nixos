"use client"

import { SidebarTrigger } from "@/components/ui/sidebar"
import { TopNavBreadcrumb } from "@/components/top-nav-breadcrumb"

// The account moved to the site header; the bar keeps the sidebar toggle and the path.
export function AppTopNav() {
  return (
    <div className="site-crumbs flex h-12 shrink-0 items-center gap-3">
      <SidebarTrigger className="-ms-1 shrink-0" />
      <TopNavBreadcrumb />
    </div>
  )
}
