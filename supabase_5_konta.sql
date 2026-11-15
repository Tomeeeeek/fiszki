-- =====================================================================
--  Aktualizacja 5: konta z hasłem
--  Wymaga aktualizacji 2–4.
--  Wklej całość w Supabase: SQL Editor → New query → Run.
--  Najpierw na bazie testowej, przy publikacji na produkcyjnej
--  (na produkcyjnej uruchom tuż przed wypchnięciem strony – stara strona
--   przestaje wtedy zapisywać postęp i obsługiwać znajomych).
--
--  • Każdy loguje się imieniem i nazwiskiem oraz hasłem.
--  • Obecni użytkownicy nie mają hasła – ustawiają je przy pierwszym logowaniu.
--  • Konto „Tomek Grupa” dostaje dotychczasowe hasło administratora.
--  • Przeglądarka po zalogowaniu dostaje losowy token sesji (zamiast id + imienia).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- Jedno konto na imię i nazwisko (bez względu na wielkość liter) -------------
do $$
declare v text;
begin
  select string_agg(n, ', ') into v from (
    select lower(imie_nazwisko) n from public.uzytkownicy group by 1 having count(*) > 1) d;
  if v is not null then
    raise exception 'Te imiona występują w bazie kilka razy: %. Usuń duplikaty i uruchom plik ponownie.', v;
  end if;
end $$;
drop index if exists public.uzytkownicy_nazwa_idx;
create unique index if not exists uzytkownicy_nazwa_uidx on public.uzytkownicy (lower(imie_nazwisko));

alter table public.uzytkownicy add column if not exists haslo text;            -- hash bcrypt; null = jeszcze nie ustawione
alter table public.uzytkownicy add column if not exists administrator boolean not null default false;

-- Konto administratora z dotychczasowym hasłem administratora
insert into public.uzytkownicy (imie_nazwisko) select 'Tomek Grupa'
 where not exists (select 1 from public.uzytkownicy where lower(imie_nazwisko) = 'tomek grupa');
update public.uzytkownicy
   set administrator = true,
       haslo = coalesce(haslo, (select wartosc from public.ustawienia where klucz = 'haslo_admina'))
 where lower(imie_nazwisko) = 'tomek grupa';

-- Sesje ------------------------------------------------------------------
create table if not exists public.sesje (
  token        uuid primary key default gen_random_uuid(),
  uzytkownik   uuid not null references public.uzytkownicy (id) on delete cascade,
  utworzono    timestamptz not null default now(),
  ostatnio     timestamptz not null default now()
);
create index if not exists sesje_uzytkownik_idx on public.sesje (uzytkownik);
alter table public.sesje enable row level security;
revoke all on public.sesje from anon, authenticated;

-- Stare funkcje (logowanie samym imieniem) przestają działać ----------------
drop function if exists public.zglos_uzytkownika(uuid, text, text, boolean);
drop function if exists public.zapisz_postep(uuid, text, jsonb);
drop function if exists public.lista_uzytkownikow(text);
drop function if exists public.szukaj_uzytkownikow(uuid, text, text);
drop function if exists public.zapros_znajomego(uuid, text, uuid);
drop function if exists public.odpowiedz_na_zaproszenie(uuid, text, uuid, boolean);
drop function if exists public.usun_znajomego(uuid, text, uuid);
drop function if exists public.moi_znajomi(uuid, text);
drop function if exists public.postep_znajomego(uuid, text, uuid);
drop function if exists public._ja(uuid, text);

-- Pomocnicze ---------------------------------------------------------------
create or replace function public._nazwa(p text) returns text
language sql immutable as $$ select btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g')) $$;

-- Kto jest zalogowany (token ważny 180 dni od ostatniego użycia)
create or replace function public._sesja(p_token uuid) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  update sesje set ostatnio = now()
   where token = p_token and ostatnio > now() - interval '180 days'
   returning uzytkownik into v_id;
  if v_id is null then raise exception 'Sesja wygasła – zaloguj się ponownie' using errcode = 'KN401'; end if;
  return v_id;
end $$;

create or replace function public._admin(p_token uuid) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid := _sesja(p_token);
begin
  if not exists (select 1 from uzytkownicy where id = v_id and administrator) then
    raise exception 'Brak uprawnień administratora' using errcode = '42501';
  end if;
  return v_id;
end $$;

create or replace function public._nowa_sesja(p_id uuid, p_urzadzenie text, p_nowa_wizyta boolean) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_token uuid; v_u uzytkownicy;
begin
  delete from sesje where uzytkownik = p_id and ostatnio < now() - interval '180 days';
  insert into sesje (uzytkownik) values (p_id) returning token into v_token;
  update uzytkownicy set ostatnia_aktywnosc = now(),
         liczba_wejsc = liczba_wejsc + case when p_nowa_wizyta then 1 else 0 end,
         urzadzenie = coalesce(left(p_urzadzenie, 40), urzadzenie)
   where id = p_id returning * into v_u;
  return jsonb_build_object('token', v_token, 'nazwa', v_u.imie_nazwisko, 'admin', v_u.administrator);
end $$;

revoke all on function public._nazwa(text) from public, anon, authenticated;
revoke all on function public._sesja(uuid) from public, anon, authenticated;
revoke all on function public._admin(uuid) from public, anon, authenticated;
revoke all on function public._nowa_sesja(uuid, text, boolean) from public, anon, authenticated;

-- Zakładanie konta ----------------------------------------------------------
create or replace function public.zaloz_konto(p_nazwa text, p_haslo text, p_urzadzenie text) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_nazwa text := _nazwa(p_nazwa); v_id uuid;
begin
  if length(v_nazwa) > 80 or array_length(string_to_array(v_nazwa, ' '), 1) < 2
     or exists (select 1 from unnest(string_to_array(v_nazwa, ' ')) w where length(w) < 2) then
    raise exception 'Wpisz pełne imię i nazwisko' using errcode = 'KN004';
  end if;
  if length(coalesce(p_haslo, '')) < 6 then raise exception 'Hasło jest za krótkie' using errcode = 'KN005'; end if;
  if exists (select 1 from uzytkownicy where lower(imie_nazwisko) = lower(v_nazwa)) then
    raise exception 'Konto o tym imieniu i nazwisku już istnieje' using errcode = 'KN003';
  end if;
  insert into uzytkownicy (imie_nazwisko, urzadzenie, haslo)
    values (v_nazwa, left(p_urzadzenie, 40), crypt(p_haslo, gen_salt('bf'))) returning id into v_id;
  return _nowa_sesja(v_id, p_urzadzenie, false);
end $$;

-- Logowanie -------------------------------------------------------------------
-- Błędy: KN001 – nie ma takiego konta, KN002 – konto bez hasła (trzeba je ustawić),
--        28P01 – złe hasło.
create or replace function public.zaloguj(p_nazwa text, p_haslo text, p_urzadzenie text) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_u uzytkownicy;
begin
  select * into v_u from uzytkownicy where lower(imie_nazwisko) = lower(_nazwa(p_nazwa));
  if v_u.id is null then raise exception 'Nie ma takiego konta' using errcode = 'KN001'; end if;
  if v_u.haslo is null then raise exception 'Konto nie ma jeszcze hasła' using errcode = 'KN002'; end if;
  if v_u.haslo <> crypt(coalesce(p_haslo, ''), v_u.haslo) then
    perform pg_sleep(1);   -- spowalnia zgadywanie hasła
    raise exception 'Nieprawidłowe hasło' using errcode = '28P01';
  end if;
  return _nowa_sesja(v_u.id, p_urzadzenie, true);
end $$;

-- Pierwsze ustawienie hasła (obecni użytkownicy i konta po resecie hasła) -------
create or replace function public.ustaw_haslo(p_nazwa text, p_haslo text, p_urzadzenie text) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_id uuid;
begin
  if length(coalesce(p_haslo, '')) < 6 then raise exception 'Hasło jest za krótkie' using errcode = 'KN005'; end if;
  update uzytkownicy set haslo = crypt(p_haslo, gen_salt('bf'))
   where lower(imie_nazwisko) = lower(_nazwa(p_nazwa)) and haslo is null
   returning id into v_id;
  if v_id is null then raise exception 'To konto ma już hasło' using errcode = 'KN006'; end if;
  return _nowa_sesja(v_id, p_urzadzenie, true);
end $$;

create or replace function public.wyloguj(p_token uuid) returns void
language sql security definer set search_path = public
as $$ delete from sesje where token = p_token $$;

-- Obecność na stronie (co 30 s) i przy otwarciu strony ----------------------------
create or replace function public.zglos(p_token uuid, p_urzadzenie text, p_nowa_wizyta boolean) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_ja uuid := _sesja(p_token); v_u uzytkownicy;
begin
  update uzytkownicy set ostatnia_aktywnosc = now(),
         liczba_wejsc = liczba_wejsc + case when p_nowa_wizyta then 1 else 0 end,
         urzadzenie = coalesce(left(p_urzadzenie, 40), urzadzenie)
   where id = v_ja returning * into v_u;
  return jsonb_build_object('nazwa', v_u.imie_nazwisko, 'admin', v_u.administrator);
end $$;

create or replace function public.zapisz_postep(p_token uuid, p_postep jsonb) returns boolean
language plpgsql security definer set search_path = public
as $$
declare v_ja uuid := _sesja(p_token);
begin
  if p_postep is null or jsonb_typeof(p_postep) <> 'object' or pg_column_size(p_postep) > 60000 then
    raise exception 'Nieprawidłowe dane postępu';
  end if;
  update uzytkownicy set postep = p_postep, postep_aktualizacja = now(), ostatnia_aktywnosc = now()
   where id = v_ja;
  return found;
end $$;

-- Znajomi (jak w aktualizacji 3 i 4, ale z tokenem) -----------------------------
create or replace function public.szukaj_uzytkownikow(p_token uuid, p_fraza text)
returns table (publiczne_id uuid, imie_nazwisko text, relacja text)
language plpgsql security definer set search_path = public
as $$
declare
  v_ja uuid := _sesja(p_token);
  v_f text := _nazwa(p_fraza);
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

create or replace function public.zapros_znajomego(p_token uuid, p_kogo uuid) returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_ja uuid := _sesja(p_token);
  v_on uuid := (select id from uzytkownicy where publiczne_id = p_kogo);
begin
  if v_on is null or v_on = v_ja then raise exception 'Nie ma takiego użytkownika'; end if;
  update znajomi set status = 'znajomi' where od = v_on and do_kogo = v_ja and status = 'oczekuje';
  if found then return 'znajomi'; end if;
  if exists (select 1 from znajomi where od = v_on and do_kogo = v_ja) then return 'znajomi'; end if;
  insert into znajomi (od, do_kogo) values (v_ja, v_on) on conflict do nothing;
  return (select case when status = 'znajomi' then 'znajomi' else 'wyslane' end
            from znajomi where od = v_ja and do_kogo = v_on);
end $$;

create or replace function public.odpowiedz_na_zaproszenie(p_token uuid, p_kto uuid, p_przyjmij boolean) returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_ja uuid := _sesja(p_token);
  v_on uuid := (select id from uzytkownicy where publiczne_id = p_kto);
begin
  if p_przyjmij then
    update znajomi set status = 'znajomi' where od = v_on and do_kogo = v_ja and status = 'oczekuje';
  else
    delete from znajomi where od = v_on and do_kogo = v_ja and status = 'oczekuje';
  end if;
  return found;
end $$;

create or replace function public.usun_znajomego(p_token uuid, p_kto uuid) returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_ja uuid := _sesja(p_token);
  v_on uuid := (select id from uzytkownicy where publiczne_id = p_kto);
begin
  delete from znajomi where (od = v_ja and do_kogo = v_on) or (od = v_on and do_kogo = v_ja);
  return found;
end $$;

create or replace function public.moi_znajomi(p_token uuid)
returns table (publiczne_id uuid, imie_nazwisko text, rodzaj text, ostatnia_aktywnosc timestamptz, od_kiedy timestamptz)
language plpgsql security definer set search_path = public
as $$
declare v_ja uuid := _sesja(p_token);
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

create or replace function public.postep_znajomego(p_token uuid, p_kto uuid)
returns table (imie_nazwisko text, postep jsonb, postep_aktualizacja timestamptz, ostatnia_aktywnosc timestamptz)
language plpgsql security definer set search_path = public
as $$
declare
  v_ja uuid := _sesja(p_token);
  v_on uuid := (select id from uzytkownicy where publiczne_id = p_kto);
begin
  if v_on is null or not exists (
    select 1 from znajomi where status = 'znajomi'
       and ((od = v_ja and do_kogo = v_on) or (od = v_on and do_kogo = v_ja))
  ) then
    raise exception 'To nie jest Twój znajomy' using errcode = '42501';
  end if;
  return query
    select u.imie_nazwisko, u.postep, u.postep_aktualizacja, u.ostatnia_aktywnosc
      from uzytkownicy u where u.id = v_on;
end $$;

-- Panel administratora --------------------------------------------------------
create or replace function public.lista_uzytkownikow(p_token uuid)
returns table (
  publiczne_id uuid, imie_nazwisko text, pierwsze_wejscie timestamptz, ostatnia_aktywnosc timestamptz,
  liczba_wejsc integer, urzadzenie text, postep jsonb, postep_aktualizacja timestamptz,
  ma_haslo boolean, administrator boolean
)
language plpgsql security definer set search_path = public
as $$
begin
  perform _admin(p_token);
  return query
    select u.publiczne_id, u.imie_nazwisko, u.pierwsze_wejscie, u.ostatnia_aktywnosc, u.liczba_wejsc, u.urzadzenie,
           u.postep, u.postep_aktualizacja, u.haslo is not null, u.administrator
      from uzytkownicy u order by u.ostatnia_aktywnosc desc;
end $$;

-- Reset hasła: osoba ustawi nowe przy następnym logowaniu; wylogowuje ją wszędzie
create or replace function public.admin_resetuj_haslo(p_token uuid, p_kto uuid) returns boolean
language plpgsql security definer set search_path = public
as $$
declare v_on uuid;
begin
  perform _admin(p_token);
  update uzytkownicy set haslo = null where publiczne_id = p_kto and not administrator returning id into v_on;
  delete from sesje where uzytkownik = v_on;
  return v_on is not null;
end $$;

create or replace function public.admin_usun_konto(p_token uuid, p_kto uuid) returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  perform _admin(p_token);
  delete from uzytkownicy where publiczne_id = p_kto and not administrator;   -- sesje i znajomi znikają kaskadowo
  return found;
end $$;

-- Liczba opanowanych fiszek z podsumowania postępu (do wyboru lepszego postępu)
create or replace function public._opanowane(p jsonb) returns integer
language sql immutable as $$
  select coalesce(sum((r->>'mastered')::int), 0)::int
    from jsonb_array_elements(coalesce(p->'groups', '[]')) g,
         jsonb_array_elements(coalesce(g->'rounds', '[]')) r
   where not coalesce((r->>'all')::boolean, false)
$$;
revoke all on function public._opanowane(jsonb) from public, anon, authenticated;

-- Połączenie kont: p_usuwane znika, jego znajomi i wizyty przechodzą na p_zostaje,
-- zostaje lepszy postęp (więcej opanowanych fiszek), hasło konta, które zostaje (albo usuwanego, gdy brak).
create or replace function public.admin_polacz_konta(p_token uuid, p_zostaje uuid, p_usuwane uuid) returns boolean
language plpgsql security definer set search_path = public
as $$
declare a uzytkownicy; b uzytkownicy;
begin
  perform _admin(p_token);
  select * into a from uzytkownicy where publiczne_id = p_zostaje;
  select * into b from uzytkownicy where publiczne_id = p_usuwane;
  if a.id is null or b.id is null or a.id = b.id then raise exception 'Nieprawidłowe konta'; end if;
  if b.administrator then raise exception 'Nie można usunąć konta administratora'; end if;

  -- znajomości usuwanego konta przechodzą na konto, które zostaje (bez duplikatów i bez znajomości z samym sobą)
  delete from znajomi where (od = a.id and do_kogo = b.id) or (od = b.id and do_kogo = a.id);
  -- ta sama osoba przy obu kontach: zostaje silniejsza relacja (znajomi > zaproszenie)
  update znajomi y set status = 'znajomi'
   where y.status = 'oczekuje' and (y.od = a.id or y.do_kogo = a.id)
     and exists (select 1 from znajomi z where z.status = 'znajomi'
                   and ((z.od = b.id and z.do_kogo = case when y.od = a.id then y.do_kogo else y.od end)
                     or (z.do_kogo = b.id and z.od = case when y.od = a.id then y.do_kogo else y.od end)));
  -- pozostałe przenosimy; powtórzone relacje znikną razem z kontem b
  update znajomi z set od = a.id where z.od = b.id
     and not exists (select 1 from znajomi y where (y.od = a.id and y.do_kogo = z.do_kogo) or (y.od = z.do_kogo and y.do_kogo = a.id));
  update znajomi z set do_kogo = a.id where z.do_kogo = b.id
     and not exists (select 1 from znajomi y where (y.od = a.id and y.do_kogo = z.od) or (y.od = z.od and y.do_kogo = a.id));

  update uzytkownicy set
    pierwsze_wejscie   = least(a.pierwsze_wejscie, b.pierwsze_wejscie),
    ostatnia_aktywnosc = greatest(a.ostatnia_aktywnosc, b.ostatnia_aktywnosc),
    liczba_wejsc       = a.liczba_wejsc + b.liczba_wejsc,
    haslo              = coalesce(a.haslo, b.haslo),
    postep             = case when _opanowane(b.postep) > _opanowane(a.postep) then b.postep else a.postep end,
    postep_aktualizacja = case when _opanowane(b.postep) > _opanowane(a.postep) then b.postep_aktualizacja else a.postep_aktualizacja end
   where id = a.id;
  update sesje set uzytkownik = a.id where uzytkownik = b.id;   -- zalogowani na starym koncie są teraz na nowym
  delete from uzytkownicy where id = b.id;
  return true;
end $$;

-- Uprawnienia --------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'zaloz_konto(text, text, text)', 'zaloguj(text, text, text)', 'ustaw_haslo(text, text, text)', 'wyloguj(uuid)',
    'zglos(uuid, text, boolean)', 'zapisz_postep(uuid, jsonb)',
    'szukaj_uzytkownikow(uuid, text)', 'zapros_znajomego(uuid, uuid)', 'odpowiedz_na_zaproszenie(uuid, uuid, boolean)',
    'usun_znajomego(uuid, uuid)', 'moi_znajomi(uuid)', 'postep_znajomego(uuid, uuid)',
    'lista_uzytkownikow(uuid)', 'admin_resetuj_haslo(uuid, uuid)', 'admin_usun_konto(uuid, uuid)',
    'admin_polacz_konta(uuid, uuid, uuid)']
  loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;
