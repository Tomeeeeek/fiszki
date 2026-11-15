-- =====================================================================
--  Aktualizacja 4: oglądanie statystyk znajomych
--  Wymaga aktualizacji 3 (supabase_3_znajomi.sql).
--  Wklej całość w Supabase: SQL Editor → New query → Run.
--  Najpierw na bazie testowej, przy publikacji na produkcyjnej.
-- =====================================================================

-- Postęp znajomego – tylko gdy zaproszenie zostało przyjęte (działa w obie strony)
create or replace function public.postep_znajomego(p_id uuid, p_nazwa text, p_kto uuid)
returns table (imie_nazwisko text, postep jsonb, postep_aktualizacja timestamptz,
               ostatnia_aktywnosc timestamptz)
language plpgsql security definer set search_path = public
as $$
declare
  v_ja uuid := _ja(p_id, p_nazwa);
  v_on uuid := (select id from uzytkownicy where publiczne_id = p_kto);
begin
  if v_on is null or not exists (
    select 1 from znajomi
     where status = 'znajomi'
       and ((od = v_ja and do_kogo = v_on) or (od = v_on and do_kogo = v_ja))
  ) then
    raise exception 'To nie jest Twój znajomy' using errcode = '42501';
  end if;
  return query
    select u.imie_nazwisko, u.postep, u.postep_aktualizacja, u.ostatnia_aktywnosc
      from uzytkownicy u where u.id = v_on;
end $$;

revoke all on function public.postep_znajomego(uuid, text, uuid) from public;
grant execute on function public.postep_znajomego(uuid, text, uuid) to anon, authenticated;
