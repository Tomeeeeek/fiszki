-- =====================================================================
--  Aktualizacja 3: wyszukiwanie użytkowników i znajomi
--  Wklej całość w Supabase: SQL Editor → New query → Run.
--  Najpierw na bazie testowej, przy publikacji na produkcyjnej.
--  Hasło administratora pozostaje bez zmian.
-- =====================================================================

-- Publiczny identyfikator użytkownika ------------------------------------
-- Prywatne id (uzytkownicy.id) służy przeglądarce do potwierdzenia, kim jest,
-- więc nie pokazujemy go innym. Innych użytkowników wskazuje się przez publiczne_id.
alter table public.uzytkownicy add column if not exists publiczne_id uuid not null default gen_random_uuid();
create unique index if not exists uzytkownicy_publiczne_id_idx on public.uzytkownicy (publiczne_id);

-- Znajomości i zaproszenia ----------------------------------------------
-- Jeden wiersz na parę: od = kto zaprosił, do_kogo = kogo zaproszono.
-- status: 'oczekuje' (zaproszenie) albo 'znajomi' (przyjęte).
create table if not exists public.znajomi (
  od          uuid not null references public.uzytkownicy (id) on delete cascade,
  do_kogo     uuid not null references public.uzytkownicy (id) on delete cascade,
  status      text not null default 'oczekuje' check (status in ('oczekuje', 'znajomi')),
  utworzono   timestamptz not null default now(),
  primary key (od, do_kogo),
  check (od <> do_kogo)
);
create index if not exists znajomi_do_kogo_idx on public.znajomi (do_kogo);
alter table public.znajomi enable row level security;
revoke all on public.znajomi from anon, authenticated;

-- Pomocnicze: potwierdza, że p_id i p_nazwa należą do tej samej osoby ------
create or replace function public._ja(p_id uuid, p_nazwa text) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  select id into v_id from uzytkownicy
   where id = p_id
     and lower(imie_nazwisko) = lower(btrim(regexp_replace(coalesce(p_nazwa, ''), '\s+', ' ', 'g')));
  if v_id is null then raise exception 'Nieznany użytkownik' using errcode = '28000'; end if;
  return v_id;
end $$;
revoke all on function public._ja(uuid, text) from public, anon, authenticated;

-- Wyszukiwanie użytkowników (min. 2 znaki, najwyżej 20 wyników) -------------
-- relacja: null, 'znajomi', 'wyslane' (ja zaprosiłem), 'otrzymane' (mnie zaproszono)
create or replace function public.szukaj_uzytkownikow(p_id uuid, p_nazwa text, p_fraza text)
returns table (publiczne_id uuid, imie_nazwisko text, relacja text)
language plpgsql security definer set search_path = public
as $$
declare
  v_ja uuid := _ja(p_id, p_nazwa);
  v_f text := btrim(regexp_replace(coalesce(p_fraza, ''), '\s+', ' ', 'g'));
begin
  if length(v_f) < 2 then return; end if;
  v_f := replace(replace(replace(lower(v_f), '\', '\\'), '%', '\%'), '_', '\_');
  return query
    select u.publiczne_id, u.imie_nazwisko,
           case when z.status = 'znajomi' then 'znajomi'
                when z.od = v_ja then 'wyslane'
                when z.do_kogo = v_ja then 'otrzymane' end
      from uzytkownicy u
      left join znajomi z on (z.od = v_ja and z.do_kogo = u.id) or (z.od = u.id and z.do_kogo = v_ja)
     where u.id <> v_ja and lower(u.imie_nazwisko) like '%' || v_f || '%'
     order by (lower(u.imie_nazwisko) like v_f || '%') desc, u.imie_nazwisko
     limit 20;
end $$;

-- Zaproszenie do znajomych -------------------------------------------------
-- Jeśli ta osoba już mnie zaprosiła, zaproszenie od razu zostaje przyjęte.
create or replace function public.zapros_znajomego(p_id uuid, p_nazwa text, p_kogo uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_ja uuid := _ja(p_id, p_nazwa);
  v_on uuid;
begin
  select id into v_on from uzytkownicy where publiczne_id = p_kogo;
  if v_on is null or v_on = v_ja then raise exception 'Nie ma takiego użytkownika'; end if;
  update znajomi set status = 'znajomi' where od = v_on and do_kogo = v_ja and status = 'oczekuje';
  if found then return 'znajomi'; end if;
  if exists (select 1 from znajomi where od = v_on and do_kogo = v_ja) then return 'znajomi'; end if;
  insert into znajomi (od, do_kogo) values (v_ja, v_on) on conflict do nothing;
  return (select case when status = 'znajomi' then 'znajomi' else 'wyslane' end
            from znajomi where od = v_ja and do_kogo = v_on);
end $$;

-- Odpowiedź na zaproszenie (przyjęcie albo odrzucenie) -----------------------
create or replace function public.odpowiedz_na_zaproszenie(p_id uuid, p_nazwa text, p_kto uuid, p_przyjmij boolean)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_ja uuid := _ja(p_id, p_nazwa);
  v_on uuid := (select id from uzytkownicy where publiczne_id = p_kto);
begin
  if p_przyjmij then
    update znajomi set status = 'znajomi' where od = v_on and do_kogo = v_ja and status = 'oczekuje';
  else
    delete from znajomi where od = v_on and do_kogo = v_ja and status = 'oczekuje';
  end if;
  return found;
end $$;

-- Usunięcie znajomego albo anulowanie wysłanego zaproszenia -------------------
create or replace function public.usun_znajomego(p_id uuid, p_nazwa text, p_kto uuid)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_ja uuid := _ja(p_id, p_nazwa);
  v_on uuid := (select id from uzytkownicy where publiczne_id = p_kto);
begin
  delete from znajomi where (od = v_ja and do_kogo = v_on) or (od = v_on and do_kogo = v_ja);
  return found;
end $$;

-- Moi znajomi i zaproszenia -------------------------------------------------
-- rodzaj: 'znajomi', 'otrzymane' (czekają na moją odpowiedź), 'wyslane'
create or replace function public.moi_znajomi(p_id uuid, p_nazwa text)
returns table (publiczne_id uuid, imie_nazwisko text, rodzaj text, ostatnia_aktywnosc timestamptz, od_kiedy timestamptz)
language plpgsql security definer set search_path = public
as $$
declare v_ja uuid := _ja(p_id, p_nazwa);
begin
  return query
    select u.publiczne_id, u.imie_nazwisko,
           case when z.status = 'znajomi' then 'znajomi' when z.do_kogo = v_ja then 'otrzymane' else 'wyslane' end,
           u.ostatnia_aktywnosc, z.utworzono
      from znajomi z
      join uzytkownicy u on u.id = case when z.od = v_ja then z.do_kogo else z.od end
     where z.od = v_ja or z.do_kogo = v_ja
     order by u.imie_nazwisko;
end $$;

revoke all on function public.szukaj_uzytkownikow(uuid, text, text) from public;
revoke all on function public.zapros_znajomego(uuid, text, uuid) from public;
revoke all on function public.odpowiedz_na_zaproszenie(uuid, text, uuid, boolean) from public;
revoke all on function public.usun_znajomego(uuid, text, uuid) from public;
revoke all on function public.moi_znajomi(uuid, text) from public;
grant execute on function public.szukaj_uzytkownikow(uuid, text, text) to anon, authenticated;
grant execute on function public.zapros_znajomego(uuid, text, uuid) to anon, authenticated;
grant execute on function public.odpowiedz_na_zaproszenie(uuid, text, uuid, boolean) to anon, authenticated;
grant execute on function public.usun_znajomego(uuid, text, uuid) to anon, authenticated;
grant execute on function public.moi_znajomi(uuid, text) to anon, authenticated;
