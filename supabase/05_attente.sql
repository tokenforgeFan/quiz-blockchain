-- =====================================================================
-- « Préviens-moi » : liste d'attente par thème à venir (bouton + de l'accueil).
-- À exécuter une fois, après 04_themes.sql.
-- Les e-mails ne sont lisibles que par toi (Table Editor → theme_waitlist), jamais par les joueurs.
-- =====================================================================

create table if not exists public.theme_waitlist (
  id         bigint generated always as identity primary key,
  theme_id   text not null references public.themes(id) on delete cascade,
  email      text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 254),
  created_at timestamptz not null default now(),
  unique (theme_id, email)
);
alter table public.theme_waitlist enable row level security;
-- Aucune lecture publique. L'inscription passe uniquement par la fonction ci-dessous.

create or replace function public.join_waitlist(p_theme text, p_email text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from themes where id = p_theme and status = 'soon') then
    raise exception 'thème inconnu';
  end if;
  -- anti-abus : 20 inscriptions max par minute sur tout le site
  if (select count(*) from theme_waitlist where created_at > now() - interval '1 minute') >= 20 then
    raise exception 'trop de demandes, réessaie dans une minute';
  end if;
  insert into theme_waitlist(theme_id, email) values (p_theme, lower(trim(p_email)))
  on conflict (theme_id, email) do nothing;
end $$;
grant execute on function public.join_waitlist(text, text) to anon, authenticated;

-- Le jour où tu ouvres un thème : la liste des e-mails à prévenir
--   select email from theme_waitlist where theme_id = 'a-venir-1' order by created_at;
-- Puis, une fois prévenus (RGPD : on ne garde pas plus longtemps que nécessaire) :
--   delete from theme_waitlist where theme_id = 'a-venir-1';
