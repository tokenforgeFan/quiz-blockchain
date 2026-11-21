-- =====================================================================
-- Thèmes et jeux : la page d'accueil se construit à partir de ces tables.
-- Pour ajouter un futur quiz : une ligne dans themes, une ou plusieurs dans games.
-- À exécuter une fois, après 03_parties.sql.
-- =====================================================================

create table if not exists public.themes (
  id     text primary key,            -- 'blockchain', 'bourse', ...
  ord    int  not null,
  title  text not null,
  descr  text,
  icon   text,                        -- emoji affiché sur la carte
  status text not null default 'live' check (status in ('live','soon'))
);
create table if not exists public.games (
  id       text primary key,          -- 'quiz-blockchain', 'arcade-blockchain'
  theme_id text not null references public.themes(id) on delete cascade,
  ord      int  not null,
  title    text not null,
  descr    text,
  icon     text,
  url      text not null,
  kind     text not null check (kind in ('quiz','arcade'))
);
alter table public.themes enable row level security;
alter table public.games  enable row level security;
drop policy if exists "thèmes lisibles" on public.themes;
create policy "thèmes lisibles" on public.themes for select using (true);
drop policy if exists "jeux lisibles" on public.games;
create policy "jeux lisibles" on public.games for select using (true);
grant select on public.themes, public.games to anon, authenticated;

-- Chaque bloc de quiz appartient à un thème
alter table public.levels add column if not exists theme_id text references public.themes(id);

insert into public.themes(id, ord, title, descr, icon, status) values
  ('blockchain', 1, 'Blockchain et actifs numériques',
   'Le MOOC de l''Université de Nicosie, session par session : Bitcoin, Ethereum, DeFi, stablecoins…', '⛓', 'live'),
  ('a-venir-1', 2, 'Thème à venir', 'Bientôt', '📈', 'soon'),
  ('a-venir-2', 3, 'Thème à venir', 'Bientôt', '➕', 'soon')
on conflict (id) do update set ord=excluded.ord, title=excluded.title, descr=excluded.descr, icon=excluded.icon, status=excluded.status;

insert into public.games(id, theme_id, ord, title, descr, icon, url, kind) values
  ('quiz-blockchain',   'blockchain', 1, 'Quiz à niveaux',    '8 blocs : un cours, puis un test de 20 questions', '⛓', 'https://tokenforgefan.github.io/quiz-blockchain/',   'quiz'),
  ('arcade-blockchain', 'blockchain', 2, 'Arcade-Blockchain', 'Simulateurs, Vrai ou Faux, Paires',                '🎮', 'https://tokenforgefan.github.io/Arcade-blockchain/', 'arcade')
on conflict (id) do update set theme_id=excluded.theme_id, ord=excluded.ord, title=excluded.title, descr=excluded.descr, icon=excluded.icon, url=excluded.url, kind=excluded.kind;

update public.levels set theme_id = 'blockchain' where theme_id is null;

-- Notes Arcade : chacun peut relire les siennes (pour sa progression)
drop policy if exists "voir ses notes arcade" on public.arcade_scores;
create policy "voir ses notes arcade" on public.arcade_scores for select using (auth.uid() = user_id);
grant select on public.arcade_scores to authenticated;

-- Résumé de ma progression par thème, pour les cartes de l'accueil
create or replace function public.my_summary()
returns table(theme_id text, blocs_mines bigint, blocs_total bigint, arcade_sessions bigint)
language sql stable security definer set search_path = public as $$
  select t.id,
    (select count(distinct a.level_id) from attempts a join levels l on l.id = a.level_id
      where a.user_id = auth.uid() and a.passed and l.theme_id = t.id),
    (select count(*) from levels l where l.theme_id = t.id),
    (select count(*) from arcade_scores s where s.user_id = auth.uid())
  from themes t where t.status = 'live';
$$;
grant execute on function public.my_summary() to authenticated;
