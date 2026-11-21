-- =====================================================================
-- Parties corrigées question par question (remplace submit_quiz).
-- À exécuter une fois, après 01_schema.sql et 02_questions.sql.
-- =====================================================================

-- Une partie est « ouverte » tant qu'elle n'est pas terminée.
alter table public.attempts alter column score   drop not null;
alter table public.attempts alter column correct drop not null;
alter table public.attempts alter column wrong   drop not null;
alter table public.attempts alter column skipped drop not null;
alter table public.attempts alter column passed  drop not null;
alter table public.attempts add column if not exists finished_at timestamptz;
update public.attempts set finished_at = created_at where finished_at is null and score is not null;

create table if not exists public.attempt_answers (
  attempt_id bigint not null references public.attempts(id) on delete cascade,
  idx        int not null,
  choice     int,               -- null = question passée
  ok         boolean not null,
  primary key (attempt_id, idx)
);
alter table public.attempt_answers enable row level security;

-- L'ancienne voie d'envoi groupé est fermée : une seule façon de jouer.
drop function if exists public.submit_quiz(text, jsonb);

-- 1) Commencer une partie
create or replace function public.start_attempt(p_level text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id bigint; v_ord int;
begin
  if v_uid is null then raise exception 'non connecté'; end if;
  if not exists (select 1 from profiles where id = v_uid) then raise exception 'pseudo manquant'; end if;
  select ord into v_ord from levels where id = p_level;
  if v_ord is null then raise exception 'bloc inconnu'; end if;
  if v_ord > 1 and not exists (
      select 1 from attempts a join levels l on l.id = a.level_id
      where a.user_id = v_uid and a.passed and l.ord = v_ord - 1) then
    raise exception 'bloc verrouillé';
  end if;
  if exists (select 1 from attempts where user_id = v_uid and created_at > now() - interval '10 seconds') then
    raise exception 'trop rapide, réessaie dans quelques secondes';
  end if;
  -- Les parties laissées en plan sont abandonnées (elles ne comptent pas).
  delete from attempts where user_id = v_uid and finished_at is null;
  insert into attempts(user_id, level_id) values (v_uid, p_level) returning id into v_id;
  return v_id;
end $$;

-- 2) Répondre à une question (une seule fois) → correction immédiate
create or replace function public.answer_question(p_attempt bigint, p_idx int, p_choice int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); a record; q record; v_ok boolean;
begin
  select * into a from attempts where id = p_attempt and user_id = v_uid and finished_at is null;
  if not found then raise exception 'partie introuvable ou terminée'; end if;
  select * into q from questions where level_id = a.level_id and idx = p_idx;
  if not found then raise exception 'question inconnue'; end if;
  if exists (select 1 from attempt_answers where attempt_id = p_attempt and idx = p_idx) then
    raise exception 'question déjà répondue';
  end if;
  v_ok := p_choice is not null and p_choice = q.answer;
  insert into attempt_answers values (p_attempt, p_idx, p_choice, v_ok);
  return jsonb_build_object('ok', v_ok, 'answer', q.answer, 'explanation', q.explanation);
end $$;

-- 3) Terminer : le serveur calcule le score à partir des réponses enregistrées
create or replace function public.finish_attempt(p_attempt bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); a record; v_n int; v_ok int; v_ko int; v_skip int; v_score numeric; v_passed boolean;
begin
  select * into a from attempts where id = p_attempt and user_id = v_uid and finished_at is null;
  if not found then raise exception 'partie introuvable ou terminée'; end if;
  select count(*) into v_n from questions where level_id = a.level_id;
  select count(*) filter (where ok), count(*) filter (where not ok and choice is not null)
    into v_ok, v_ko from attempt_answers where attempt_id = p_attempt;
  v_skip  := v_n - v_ok - v_ko;              -- non répondues = passées
  v_score := greatest(0, v_ok - 0.5 * v_ko);
  v_passed := v_score >= 15;
  update attempts set score = v_score, correct = v_ok, wrong = v_ko, skipped = v_skip,
         passed = v_passed, finished_at = now() where id = p_attempt;
  return jsonb_build_object('score', v_score, 'correct', v_ok, 'wrong', v_ko, 'skipped', v_skip, 'passed', v_passed);
end $$;

-- 4) Ma progression (pour afficher la chaîne)
create or replace function public.my_progress()
returns table(level_id text, best numeric, passed boolean)
language sql stable security definer set search_path = public as $$
  select level_id, max(score), bool_or(passed) from attempts
  where user_id = auth.uid() and finished_at is not null group by level_id;
$$;

grant execute on function public.start_attempt(text)              to authenticated;
grant execute on function public.answer_question(bigint, int, int) to authenticated;
grant execute on function public.finish_attempt(bigint)            to authenticated;
grant execute on function public.my_progress()                     to authenticated;

-- Classements : seules les parties terminées comptent
create or replace view public.leaderboard_general with (security_invoker = false) as
select p.pseudo, sum(b.best) as total, count(*) filter (where b.passed) as blocs_mines,
       max(b.last_at) as derniere_partie
from (select user_id, level_id, max(score) as best, bool_or(passed) as passed, max(finished_at) as last_at
      from attempts where finished_at is not null group by user_id, level_id) b
join profiles p on p.id = b.user_id
group by p.pseudo;

create or replace view public.leaderboard_level with (security_invoker = false) as
select a.level_id, p.pseudo, max(a.score) as best, min(a.finished_at) filter (where a.passed) as mine_le
from attempts a join profiles p on p.id = a.user_id
where a.finished_at is not null
group by a.level_id, p.pseudo;

create or replace view public.leaderboard_week with (security_invoker = false) as
select p.pseudo, sum(b.best) as total, count(*) as blocs_joues
from (select user_id, level_id, max(score) as best from attempts
      where finished_at >= (date_trunc('week', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris')
      group by user_id, level_id) b
join profiles p on p.id = b.user_id
group by p.pseudo;

create or replace view public.player_badges with (security_invoker = false) as
select p.pseudo,
  (select count(distinct level_id) from attempts a where a.user_id = p.id and a.passed) as blocs_mines,
  (select count(*) from levels) as blocs_total,
  exists (select 1 from attempts a where a.user_id = p.id and a.score = 20) as sans_faute,
  exists (select 1 from attempts a where a.user_id = p.id and a.passed and a.wrong = 0 and a.skipped = 0) as parfait,
  (select count(*) from attempts a where a.user_id = p.id and a.finished_at is not null) as parties
from profiles p;

grant select on public.leaderboard_general, public.leaderboard_level,
                public.leaderboard_week, public.player_badges to anon, authenticated;
