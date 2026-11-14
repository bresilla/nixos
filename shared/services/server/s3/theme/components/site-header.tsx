"use client"

import Link from "next/link"
import { useRouter } from "next/navigation"
import { useTranslation } from "react-i18next"
import { useAuth } from "@/contexts/auth-context"
import { usePermissions } from "@/hooks/use-permissions"
import { resolveAccountDisplayName } from "@/lib/account-display"
import { getLoginRoute } from "@/lib/routes"
import { getThemeManifest } from "@/lib/theme/manifest"
import { SITE_LOGO } from "@/components/site-logo"

function Account() {
  const { t } = useTranslation()
  const router = useRouter()
  const { logoutWithOidcRedirect } = useAuth()
  const { userInfo } = usePermissions()
  const who = userInfo as { account_name?: string; username?: string; email?: string } | null
  const name = resolveAccountDisplayName({
    access_key: who?.account_name ?? "",
    username: who?.username,
    email: who?.email,
  })

  const signOut = async (event: React.MouseEvent) => {
    event.preventDefault()
    if (!(await logoutWithOidcRedirect())) router.push(getLoginRoute())
  }

  return (
    <>
      {name ? (
        <Link href="/account" className="mute">
          {name}
        </Link>
      ) : null}
      <a href="#" className="item" onClick={signOut}>
        {t("Sign out")}
      </a>
    </>
  )
}

// The header of git, cache, build and id: header.html's markup, drawn by React.
export function SiteHeader({ signedIn = false }: { signedIn?: boolean }) {
  return (
    <header className="site">
      <span className="site-logo" dangerouslySetInnerHTML={{ __html: SITE_LOGO }} />
      <Link href="/">{getThemeManifest().brand.name}</Link>
      <nav />
      <div className="who">{signedIn ? <Account /> : null}</div>
    </header>
  )
}
