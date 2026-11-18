-- =====================================================================
--  Aktualizacja 8: zgłoszenia do administratora (problemy, skargi, pomysły)
--  Wymaga aktualizacji 5–7.
--  Wklej całość w Supabase: SQL Editor → New query → Run.
--  Najpierw na bazie testowej, przy publikacji na produkcyjnej.
--
--  • Każdy zalogowany użytkownik może wysłać kartę: rodzaj + treść
--    (+ opcjonalnie fiszka, przy której był, i widok strony).
--  • Administrator widzi listę kart w panelu „Użytkownicy” → „Zgłoszenia”,
--    może je oznaczać (nowe / przeczytane / zrobione) i usuwać.
-- =====================================================================

create table if not exists public.zgloszenia (
  id           bigint generated always as identity primary key,
  uzytkownik   uuid references public.uzytkownicy (id) on delete set null,
  autor        text not null,                       -- imię i nazwisko z chwili wysłania
  rodzaj       text not null check (rodzaj in ('problem', 'skarga', 'pomysl')),
  tresc        text not null,
  miejsce      text,                                -- np. „Fiszka: … (porcja …)”
  urzadzenie   text,
  status       text not null default 'nowe' check (status in ('nowe', 'przeczytane', 'zrobione')),
  utworzono    timestamptz not null default now()
);
create index if not exists zgloszenia_utworzono_idx on public.zgloszenia (utworzono desc);
create index if not exists zgloszenia_uzytkownik_idx on public.zgloszenia (uzytkownik, utworzono);
alter table public.zgloszenia enable row level security;
revoke all on public.zgloszenia from anon, authenticated;

-- Wysłanie karty ----------------------------------------------------------------
create or replace function public.wyslij_zgloszenie(p_token uuid, p_rodzaj text, p_tresc text, p_miejsce text, p_urzadzenie text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare v_ja uuid := _sesja(p_token); v_tresc text := btrim(coalesce(p_tresc, ''));
begin
  if p_rodzaj not in ('problem', 'skarga', 'pomysl') then raise exception 'Nieznany rodzaj zgłoszenia'; end if;
  if length(v_tresc) < 3 then raise exception 'Opisz zgłoszenie' using errcode = 'KN010'; end if;
  if length(v_tresc) > 4000 then raise exception 'Zgłoszenie jest za długie' using errcode = 'KN011'; end if;
  if (select count(*) from zgloszenia where uzytkownik = v_ja and utworzono > now() - interval '1 day') >= 20 then
    raise exception 'Za dużo zgłoszeń jednego dnia – spróbuj jutro' using errcode = 'KN012';
  end if;
  insert into zgloszenia (uzytkownik, autor, rodzaj, tresc, miejsce, urzadzenie)
    select v_ja, u.imie_nazwisko, p_rodzaj, v_tresc, left(nullif(btrim(p_miejsce), ''), 300), left(p_urzadzenie, 40)
      from uzytkownicy u where u.id = v_ja;
  return true;
end $$;

-- Lista kart (administrator) -----------------------------------------------------
create or replace function public.admin_zgloszenia(p_token uuid)
returns table (id bigint, autor text, publiczne_id uuid, rodzaj text, tresc text, miejsce text,
               urzadzenie text, status text, utworzono timestamptz)
language plpgsql security definer set search_path = public
as $$
begin
  perform _admin(p_token);
  return query
    select z.id, z.autor, u.publiczne_id, z.rodzaj, z.tresc, z.miejsce, z.urzadzenie, z.status, z.utworzono
      from zgloszenia z left join uzytkownicy u on u.id = z.uzytkownik
     order by (z.status = 'zrobione'), z.utworzono desc
     limit 500;
end $$;

create or replace function public.admin_zgloszenie_status(p_token uuid, p_id bigint, p_status text) returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  perform _admin(p_token);
  if p_status not in ('nowe', 'przeczytane', 'zrobione') then raise exception 'Nieznany status'; end if;
  update zgloszenia set status = p_status where id = p_id;
  return found;
end $$;

create or replace function public.admin_usun_zgloszenie(p_token uuid, p_id bigint) returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  perform _admin(p_token);
  delete from zgloszenia where id = p_id;
  return found;
end $$;

do $$
declare f text;
begin
  foreach f in array array['wyslij_zgloszenie(uuid, text, text, text, text)', 'admin_zgloszenia(uuid)',
    'admin_zgloszenie_status(uuid, bigint, text)', 'admin_usun_zgloszenie(uuid, bigint)']
  loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;
