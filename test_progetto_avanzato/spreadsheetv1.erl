%%%-------------------------------------------------------------------
%%% @author daniros
%%% @copyright (C) 2024, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 19. mar 2024 18:30
%%%-------------------------------------------------------------------
-module(spreadsheetv1).
-author("daniros").


-record(cell, {id, row, column, value}).
-record(tab, {name, cells_ids=[]}).
-record(sheet, {name, tab_ids=[], owner_pid, access_policies=[]}).



%% API
-export([init/0, start/0, populate_cell/4, new/1, new/4, share/2, set/5, get/4, get/5, set/6,
  to_csv/1, to_csv/2, from_cvs/1, from_cvs/2, info/1, add_row/2, del_row/3]).


init() ->
  Nodes= nodes() ++ [node()],
  mnesia:create_schema([node()|nodes()]),
  mnesia:start(),
  create_tables(Nodes),
  mnesia:stop()
.

create_tables(Nodes) ->
  mnesia:create_table(cell, [{attributes, record_info(fields, cell)},{disc_copies,Nodes}]),
  mnesia:create_table(tab, [{attributes, record_info(fields, tab)},{disc_copies,Nodes}]),
  mnesia:create_table(sheet, [{attributes, record_info(fields, sheet)},{disc_copies,Nodes}])
.

start() ->
  Nodes= nodes() ++ [node()],
  mnesia:start(),
  mnesia:change_config(extra_db_nodes, Nodes),
  mnesia:wait_for_tables([sheet,tab,cell], 20000)
.


new(Name) ->
  new(Name, 6, 3, 1)
.

new(Name, N, M, K) ->
  %% controllo se stiamo cercando di inserire un foglio già esistente
  case sheet_alredy_exists(Name) of
    true ->
      {error, 'sheet already exists'};
    false ->
      try
        %% inizio con la creazione delle celle
        {atomic, CellIds} = mnesia:transaction(fun() -> populate_cell(Name, K, N, M) end),
        %% avendo il riferimento per ogni singola cella creo il tab
        F = fun() ->
          populate_tab(Name, K, CellIds),
          SheetPageRef = lists:seq(1,K),
          %% creato il TAB, infine creo lo Sheet
          Sheet = #sheet{name = Name, tab_ids = SheetPageRef, owner_pid = node()},
          mnesia:write(Sheet)
            end,
        {atomic, Val} = mnesia:transaction(F),
        {ok, Val}
      catch
        _:Reason -> {error, Reason}
      end
  end
.

populate_cell(NameSheet, NumTab, NumRows, NumColumns) ->
  %% creo le liste per poter ciclare prima sul numero di tab
  %% per ogni tab ciclerò sulle righe
  %% per ogni riga ciclerò sulle colonne e creo l'effettiva cella
  Rows = lists:seq(1, NumRows),
  Columns = lists:seq(1, NumColumns),
  TabNumber = lists:seq(1,NumTab),
  CellIds = lists:foldl(
    fun(Tab, Acc) ->
      TabName = lists:concat([atom_to_list(NameSheet), integer_to_list(Tab)]),
      SheetCellIds = lists:foldl(
        fun(Row, AccRows) ->
          RowCellIds = lists:foldl(
            fun(Column, AccColumns) ->
              Cell = #cell{
                id = {TabName, Row, Column},
                row = Row,
                column = Column,
%%                value = undefined
                value = rand:uniform(100)
              },
              mnesia:write(Cell),
              [Cell#cell.id | AccColumns]
            end,
            [], Columns),
          RowCellIds ++ AccRows
        end,
        [], Rows),
      SheetCellIds ++ Acc
    end,
    [], TabNumber),
  lists:reverse(CellIds)
.


populate_tab(SheetPageName, NumberTab, RefCell) ->
  %% prendo il numero di TAB da creare
  Number = lists:seq(1, NumberTab),
  %% per ognuna di esse creo il TAB
  lists:foreach(
    fun(K) ->
      TabName = lists:concat([atom_to_list(SheetPageName), integer_to_list(K)]),
      %% se creo celle con 2 tab o più devo filtrare. Questo perchè se non faccio il filtro
      %% ogni tab avrebbe il riferimento a tutte le celle anche di altre tab
      %% ad esempio :
      %% spreadsheet:new(foglio,2,2,2).
      %%  PageCellIds [{"foglio1",1,1},{"foglio1",1,2},{"foglio1",2,1},{"foglio1",2,2}]
      %%  PageCellIds [{"foglio2",1,1},{"foglio2",1,2},{"foglio2",2,1},{"foglio2",2,2}]
      %%
      %% senza il filtro sia foglio1 che foglio2 avrebbero entrambi gli id e andrebbero in conflitto
      PageCellIds = lists:filter(
        fun(Cell) ->
          case Cell of
            %% se inizia con il TabName che mi interessa allora true
            {TabName, _, _} -> true;
            _ -> false
          end
        end,
        RefCell),
      Tab = #tab{name = TabName, cells_ids = PageCellIds},
      mnesia:write(Tab)
    end,
    Number)
.

sheet_alredy_exists(Name) ->
  case mnesia:dirty_read({sheet, Name}) of
    [] ->
      false;
    _  ->
      true
  end
.

get_sheet(SpreadsheetName) ->
  Sheet = mnesia:dirty_read({sheet, SpreadsheetName}),
  case Sheet of
    [] -> {error, not_found};
    [{_,_,_,_,_}] -> Sheet
  end

.

%%% AccessPolicies, da specifiche sono una lista,
%%% quindi ad esempio chiamato con [{node(),AC},{node(),AC}]
%%% Altrimenti se non passo la lista non funziona
share(SpreadsheetName, AccessPolicies) ->
  Node = node(),
  case check_format(AccessPolicies) of
    true ->
      F = fun() ->
        case mnesia:read({sheet, SpreadsheetName}) of
          %% torna una lista di sheet
          [Sheet] ->
            %% controllo se chi chiama l'operazione è l'admin del foglio
            %% poichè solo in questo caso può effettuare la modifica degli accessPolicy
            case Sheet#sheet.owner_pid =:= Node of
              true ->
                %% effettuo il controllo sugli AccessPolicies, cioè controllo se sono da modificare o inserirne nuovi
                NewAccessPolicies = update_access_policies(Sheet#sheet.access_policies, AccessPolicies),
                %% scrivo le nuove policy
                NewSheet = Sheet#sheet{access_policies = NewAccessPolicies},
                mnesia:write(NewSheet),
                ok;
              false -> {error, not_admin}
            end;
          [] ->
            {error, not_found}
        end
          end,
      TransactionResult = mnesia:transaction(F),
      TransactionResult;
    false -> io:format("hai inserito un formato sbagliato per gli AccessPolicies, la chiamata deve avere questo formato:
    :share(nomeFoglio,[{_,_},{_,_}]\n")
  end
.

check_format([]) ->
  %% Se la lista è vuota, restituisci true.
  true;

check_format([{User, _} | Rest]) when is_atom(User) ->
  %% Se il formato di questa tupla è corretto, controlla il resto della lista
  check_format(Rest);

check_format(_) ->
  %% Se il formato non è corretto, restituisci false.
  false.


update_access_policies(OldPolicies, NewPolicies) ->
  %% itero sulle NewPolicies
  lists:foldl(
    fun({NewProc, NewAP}, Acc) ->
      %% controllo se il nodo è gia esistente nella lista delle Policy esistenti
      case lists:keymember(NewProc, 1, OldPolicies) of
        true ->
          %% se esiste allora faccio un update
          %% Cerca in Acc se nella posizione 1 c'è NewProcc
          %% se c'è sostiuisce con i nuovi {NwProcc,NewAP}
          lists:keyreplace(NewProc, 1, Acc, {NewProc, NewAP});
        false ->
          %% se non esiste allora lo aggiungo
          [{NewProc, NewAP} | Acc]
      end
    end,
    OldPolicies,
    NewPolicies
  )
.

%% funzione per controllare le policy
check_policy_access(NameSpreadsheet, Process) ->
  case mnesia:dirty_read({sheet, NameSpreadsheet}) of
    [Sheet] ->
      AccessPolicies = Sheet#sheet.access_policies,
      Owner = Sheet#sheet.owner_pid,
      %% controllo se sono l'owner
      case Owner =:= Process of
        true ->
%%         %% essendo l'owner puoi fare tutto, quindi sia read che write
          {true,true};
        false ->
%%        %% restituisco la policy
          lists:keyfind(Process, 1, AccessPolicies)
      end;
    [] -> not_found
  end
.

%% funzione che restituisce il valore di una cella
get(Name, Tab, Row, Column) ->
  %% il nodo mi servirà per accedere alla lista della policy e vedere se sono abilitato all'operazione
  Node = node(),
  %% controllo se ho i diritti per poterlo fare
  case check_policy_access(Name, Node) of
    {_, _} ->
      %% essendo un get, posso farlo sia se sono read o write, quindi l'imoportante è che sono nelle policy
      PageName = lists:concat([atom_to_list(Name), integer_to_list(Tab)]),
      case mnesia:dirty_read(cell, {PageName, Row, Column}) of
        [Cell] ->
          Result = Cell#cell.value,
          Result;
        [] -> {error, not_found}
      end;
    not_found -> io:format("ERROR - spreadsheet non esistente\n"),
      {error, not_found};
    false -> io:format("ERROR - Non hai i diritti per accedere al file\n"),
      {error, no_access}
  end
.

%%% GET con Timeout
%%% si consiglia di chiamare con Timeout > 2000 perchè nella do_get, cioè l'operazione che fa effettivamente la get
%%% è impostato un timer:sleep di 2s per simulare un eventuale timeout
get(Name, Tab, Row, Column,Timeout) ->
  %% recupero il pid del processo chiamante per poter effettuare la send
  Self = self(),
  Node = node(),
  case check_policy_access(Name, Node) of
    {_, _} ->
      TabName = lists:concat([atom_to_list(Name), integer_to_list(Tab)]),
      %% creo il riferimento al chiamante per poterlo killare nel caso in cui finisca in timeout
      Caller = spawn(fun() -> do_get(TabName, Row, Column, Self) end),
      receive
        {result, Result} ->
          {ok, Result};
        {error, not_found} -> {error, not_found}
      after Timeout ->
        exit(Caller, kill),
        {error, timeout}
      end;
    not_found -> io:format("ERROR - spreadsheet non esistente\n"),
      {error, not_found};
    false -> io:format("ERROR - Non hai i diritti per accedere al file\n"),
      {error, no_access}
  end
.

%% metodo che legge il valore in cella e fa il send verso processo che lo ha richiesto
do_get(TabName, Row, Column, Ref) ->
  timer:sleep(2000),
  case mnesia:dirty_read(cell, {TabName, Row, Column}) of
    [Cell] ->
      Result = Cell#cell.value,
      Ref ! {result, Result}; % Invia il risultato al processo chiamante
    [] ->
      Ref ! {error, not_found} % Invia un messaggio di "non trovato"
  end
.

%% funzione che setta ila valore di una cella
%% come per il get ho bisogno del node() per accedere alla lista delle policy
set(Name,Tab,Row,Column, Value) ->
  Node = node(),
  TabName = lists:concat([atom_to_list(Name), integer_to_list(Tab)]),
  case check_policy_access(Name, Node) of
    %% se ho i diritti di write procedo con la scrittura
    {_,write} ->
      F = fun() ->
        case mnesia:read(cell, {TabName,Row,Column}) of
          [Cell] ->
            UpdateCell = Cell#cell{value = Value},
            mnesia:write(UpdateCell);
          [] -> {error, not_found}
        end
          end,

      case mnesia:transaction(F) of
        {atomic, Val} -> {ok,Val};
        {aborted, Reason} -> {error, Reason}
      end;
    {_,true} ->
      %% in questo caso sono il proprietario del documento e quindi posso scrivere
      F = fun() ->
        case mnesia:read(cell, {TabName,Row,Column}) of
          [Cell] ->
            UpdateCell = Cell#cell{value = Value},
            mnesia:write(UpdateCell);
          [] -> {error, not_found}
        end
          end,

      case mnesia:transaction(F) of
        {atomic, ok} -> true;
        {atomic, {error, not_found}} -> false;
        {aborted, _Reason} -> {false}
      end;
    {_,read} -> io:format("Puoi solo leggere il file\n");
    {_,_} -> {error, wrong_policies};
    not_found -> io:format("ERROR - spreadsheet non esistente\n");
    false -> io:format("ERROR - Non hai i diritti per accedere al file\n")
  end
.

%% SET con Timeout
set(Name,Tab,Row,Column, Value, Timeout) ->
  %% prendo il pid del processo chiamante, uso del do_set per fare la send del risultato
  Self = self(),
  Node = node(),
  TabName = lists:concat([atom_to_list(Name), integer_to_list(Tab)]),
  case check_policy_access(Name, Node) of
    {_,write} ->
      %% caso in cui ho le policy di scrittura
      %% riferimento al Caller per poterlo killare in caso di timeout
      Caller = spawn(fun() -> do_set(TabName, Row, Column, Value, Self) end),
      receive_response(Caller, Timeout);
    {_,true} ->
      %% caso in cui sono l'owner del file e quindi posso scrivere
      %% riferimento al Caller per poterlo killare in caso di timeout
      Caller = spawn(fun() -> do_set(TabName, Row, Column, Value, Self) end),
      receive_response(Caller, Timeout);
    {_,read} -> io:format("Puoi solo leggere il file\n");
    {_,_} -> {error, wrong_policies};
    not_found -> io:format("ERROR - spreadsheet non esistente\n");
    false -> io:format("ERROR - Non hai i diritti per accedere al file\n")
  end
.

%% metodo che effettua la write sulla cella
do_set(TabName, Row, Column, Value, Ref) ->
  timer:sleep(2000),
  F = fun() ->
    %% recupero la cella, setto il nuovo valore e faccio la write
    [Cell] = mnesia:read(cell, {TabName,Row,Column}),
    UpdateCell = Cell#cell{value = Value},
    mnesia:write(UpdateCell)
      end,
  Result = mnesia:transaction(F),
  case Result of
    {atomic, ok} -> Ref!{ok, true};
    {atomic, {error, not_found}} -> Ref!{error, not_found};
    {aborted, _Reason} -> Ref!{error, error}
  end
.

receive_response(Caller, Timeout) ->
  receive
    {ok, true} -> true;
    {error, not_found} -> false;
    {error, error} -> transaction_failed
  after Timeout ->
    exit(Caller, kill),
    {error, timeout}
  end.

%% funzione per convertire il file csv
to_csv(SpreadsheetName) ->
  do_to_cvs(SpreadsheetName, null)
.

%% funzione per convertire il file csv ma con TIMEOUT
to_csv(SpreadsheetName, Timeout) ->
  Parent = self(),
  Caller = spawn(fun() -> do_to_cvs(SpreadsheetName, Parent) end),
  receive
    {csv_data, Data} -> {ok, Data};
    {error, Reason} -> {error, Reason}
  after Timeout ->
    exit(Caller, kill),
    {error, timeout}
  end
.

do_to_cvs(SpreadsheetName, Parent) ->
  %% ho bisogno di distinguere i casi di Timeout e quelli senza
  %% nel caso senza non passo alcun riferimento al pid del processo chiamante (Parent) e quindi posso semplicemnete restituire il risultato
  %% nel caso di Timeout ho il riferimento al pid del processo e quindi devo effettuare la send
  case Parent of
    null ->
      case get_sheet(SpreadsheetName) of
        [Sheet] ->
          %% recuperato lo sheet controllo da quante TAB è composto e per ogni tab genero un file .cvs
          %% questo perchè un file .csv non ha diversi fogli come ad esempio excel che permette di farlo
          SheetTabs = Sheet#sheet.tab_ids,
          lists:foreach(fun(Tab) -> export_page_to_cvs(SpreadsheetName, Tab, Parent) end, SheetTabs),
          ok;
        {error, Reason} -> {error, Reason}
      end;
    _ ->  case get_sheet(SpreadsheetName) of
            [Sheet] ->
              SheetTabs = Sheet#sheet.tab_ids,
              lists:foreach(fun(Tab) -> export_page_to_cvs(SpreadsheetName,Tab,Parent) end, SheetTabs),
              ok;
            {error, Reason} -> Parent ! {error, Reason}
          end
  end
.

%% funzione che genera il file .csv
%% devo recuperare il tab, in questo modo ottengo l'id delle celle
%% l'id delle celle verrà usato per recuperare le righe
export_page_to_cvs(SpreadsheetName,TabName, Parent) ->
  NewTabName = lists:concat([atom_to_list(SpreadsheetName), integer_to_list(TabName)]),
  case mnesia:dirty_read(tab, NewTabName) of
    [{tab, _, CellIds}] ->
      %% prendo le righe per ogni cellIds %%
      CellForRow = [Row || {_, Row, _} <- CellIds],

      %% mi resituirà una lista fatta in questo modo: [1,1,1,2,2,2,3,3,3,4,4,4,5,5,5,6,6,6]
      %% devo quindi eliminare i duplicati
      Rows = lists:usort(CellForRow),

      %% costruisco il csv in modo tale che sarà composto da Elementi_riga_1 \n elementi_riga_2 e cosi vià
      %% Quindi per ogni riga ho bisogno di prendere il valore e manipolarli per costruire il .csv
      %% in particolare ogni valore dovrà essere seperato da virgole e uno \n a fine di ogni riga
      CsvRows = lists:map(
        fun(Row) ->
          %% get_row_values tornerà il valore per ogni riga
          RowValues = get_row_values(NewTabName, Row),
          %% per ogni elemento nella riga lo converto dal suo tipo in una stringa
          %% necessario per avere i valori comprensibili
          RowStrings = [case X of
                          Num when is_integer(Num) -> integer_to_list(Num);
                          Float when is_float(Float) -> io_lib:format("~.2f", [Float]);
                          Str when is_list(Str) -> Str;
                          Atom when is_atom(Atom) -> atom_to_list(Atom)
                        end || X <- RowValues],
          %% creo una stringa con gli elementi dove separo ogni elemento dalla virgola e alla fine metto \n
          string:join(RowStrings, ",") ++ "\n"
        end,
        Rows),

      %% "appiattisco" le stringhe per scriverle nel .csv, passaggio necessario per il write_file
      %% passaggio necessario poichè fino a questo punto CsvRow ha questo formato:
      %% ["84,29,15\n","26,9,21\n","86,88,10\n","27,85,76\n","8,91,94\n","81,37,67\n"]
      %% quindi viene vista come una lista di lista di caratteri e ho necessità che diventi una stringa unica
      %% e infine creo il file

      CsvContent = lists:flatten(CsvRows),
      StringSpreadsheetName = atom_to_list(SpreadsheetName),
      FilePath = StringSpreadsheetName ++ "_" ++ integer_to_list(TabName) ++ ".csv",
      file:write_file(FilePath, CsvContent),
      case Parent of
        null ->  {ok, FilePath};
        _ -> Parent ! {csv_data, FilePath}
      end;
    {error, Reason} ->
      case Parent of
        null -> {error, Reason};
        _ -> Parent ! {error, Reason}
      end
  end
.

get_row_values(TabName, Rows) ->
  %% faccio la query per cercare tutte le righe %%
  RowCells = mnesia:dirty_match_object({cell, {TabName, Rows, '_'}, '_', '_', '_'}),

  %% costretto ad ordinare RowCells, altrimenti il dirty_match_object non torna dati ordinati ad esempio:
  %% RowCells [{cell,{"foglio1",1,1},1,1,84},
  %%          {cell,{"foglio1",1,3},1,3,15},
  %%          {cell,{"foglio1",1,2},1,2,29}]
  %% quindi devo confrontare in base all'indice della colonna per riordinali
  SortedCells = lists:sort(fun(A, B) -> A#cell.column < B#cell.column end, RowCells),
  %% per ogni riga torno il valore, quindi nell'esempio sopra tornerò [84,29,15]
  [Value || #cell{value = Value} <- SortedCells].


%% funzione che preso un file .cvs popola la tabella in Mnesia
from_cvs(FilePath) ->
  do_from_cvs(FilePath,null)
.

%% funzione che preso un file .cvs popola la tabella in Mnesia + TIMEOUT
from_cvs(FilePath, Timeout) ->
  Parent = self(),
  Caller = spawn(fun() -> do_from_cvs(FilePath, Parent) end),
  receive
    {ok, ok} -> ok;
    {error, Reason} -> {error, Reason}
  after Timeout ->
    exit(Caller, kill),
    {error, timeout}
  end
.

do_from_cvs(FilePath, Parent) ->
  case file:open(FilePath, [read]) of
    {ok, File} ->
      %% recupero il nome del file per poter creare il record sheet di Mnesia
      %% manipolandolo in stringa prendendo solo tutto ciò che si trova prima dell'estensione .cvs
      BaseName = filename:basename(FilePath),
      NameWithoutExtension = list_to_atom(string:substr(BaseName, 1, string:rstr(BaseName, ".") - 1)),

      %% leggo il file, quindi mi creo una lista di liste, dove ogni lista corrisponde alla riga del file
      CsvData = read_lines(File, []),
      {RowCount, ColumnCount} = get_row_column_count(CsvData),
      %% utilizzo la funzione new per creare il record sheet, sheet_name, cell
      case new(NameWithoutExtension, RowCount, ColumnCount, 1) of
        {error, 'sheet already exists'} -> io:format("Foglio già esistente, cambiare il nome \n");
        _ ->
          %% se non ci sono stati problemi, ho creato i record. Ora devo settare i valori nelle celle
          %% quindi come faccio nella funzione new, per ogni riga prendo ogni colonna e per ogni colonna setto il valore
          RowCounter = lists:seq(1,RowCount),
          ColumnCounter = lists:seq(1, ColumnCount),
          lists:foreach(
            fun(RowIndex) ->
              %% ho bisogno di prendere i valori per la riga corretta
              %% quindi prima giro riga 1, secondo giro riga 2 e così via
              Row = lists:nth(RowIndex, CsvData),
              lists:foreach(
                fun(ColumnIndex) ->
                  %% allo stesso modo, fissata la riga, devo prendere il valore corretto sull'indice della colonna interessata
                  ValueString = lists:nth(ColumnIndex, Row),
                  %% pulisco lo \n presente nella stringa
                  CleanValue = string:strip(ValueString, right, $\n),
                  ParsedValue = parse_value(CleanValue),
                  %% ora scriverò il valore nella cella corrispondente
                  set(NameWithoutExtension, 1, RowIndex, ColumnIndex, ParsedValue)
                end,
                ColumnCounter)
            end,
            RowCounter),
          %%  {CsvData, RowCount, ColumnCount},
          case Parent of
            null -> ok;
            _ -> Parent ! {ok, ok}
          end
      end;
    {error, Reason} ->
      case Parent of
        null -> {error, Reason};
        _ -> Parent ! {error, Reason}
      end
  end
.


read_lines(File, Acc) ->
  %% lettura di una riga
  case file:read_line(File) of
    {ok, Line} ->
      %% letta la riga, ad esempio: "80,3,17\n"
      %% devo dividere ogni singolo elemento, cioè devo avere singolarmente 80 poi 3 poi 17
      %% quindi tokenizzo la stringa
      Tokens = string:tokens(Line, ","),
      %% chiamo ricorsivamente per aggiungere elementi alla lista
      read_lines(File, [Tokens | Acc]);
    eof ->
      %% fine del file, quindi chiudo
      file:close(File),
      lists:reverse(Acc);
    {error, Reason} ->
      file:close(File),
      {error, Reason}
  end.


get_row_column_count(CsvData) ->
  %% lunghezza della lista, ottengo il numero di righe
  RowCount = length(CsvData),
  %% numero di colonne, prendo la lunghezza della prima riga
  ColumnCount = length(hd(CsvData)),
  {RowCount, ColumnCount}.

parse_value(Value) ->
  case catch list_to_integer(Value) of
    {'EXIT', _} ->
      case catch list_to_float(Value) of
        {'EXIT', _} ->
          case Value of
            "true" -> true;
            "false" -> false;
            _ -> Value
          end;
        Float -> Float
      end;
    Int -> Int
  end.


%% metodo che torna le informazioni:
%% permessi di lettura scrittura e numero di celle x tab
info(Name) ->
  %% recupero lo sheet
  case get_sheet(Name) of
    [Sheet] ->
      %% leggo i permessi e li stampo
      AccessPolicies = Sheet#sheet.access_policies,
      io:format("Permessi: ~p\n", [AccessPolicies]),
      %% per ogni Tab vedo la lunghezza degli della lista delle id delle celle, ottenendo così il numero di celle
      %% e quindi riporto il numero di celle x tab
      TabCellCounts = lists:map(fun(Tab) ->
        PageName = lists:concat([atom_to_list(Name), integer_to_list(Tab)]),
        case mnesia:dirty_read(tab, PageName) of
          [{tab, _, CellIds}] ->
            {length(CellIds),Tab};
          _ ->
            {Tab, 0}
        end
                                end, Sheet#sheet.tab_ids),
      io:format("numero di celle x tab: ~p\n", [TabCellCounts]);
    _ ->
      {error, not_found}
  end
.

add_row(NameSheet, Tab) ->
  %% Trova il numero di colonne nel tab
  TabName = lists:concat([atom_to_list(NameSheet), integer_to_list(Tab)]),
  case mnesia:dirty_read(tab, TabName) of
    [{tab, _, CellIds}] ->
      ColumnsIndex = [Column || {_,_, Column} <- CellIds],
      %% Incrementa il numero di righe per il tab
      RowNumbers = [Row || {_, Row, _} <- CellIds],

      %% mi resituirà una lista fatta in questo modo: [1,1,1,2,2,2,3,3,3,4,4,4,5,5,5,6,6,6]
      %% devo quindi eliminare i duplicati
      NewRowIndex = length(lists:usort(RowNumbers)) +1,
      NumColumns = length(lists:usort(ColumnsIndex)),
%%      io:format("NumColumns ~p\n", [NumColumns]),
%%      io:format("NewRowIndex ~p\n", [NewRowIndex]),
      %% Per ogni colonna nel tab, crea una nuova cella con il valore desiderato
      F = fun () ->
        lists:foreach(
          fun(Column) ->
            NewCellId = {TabName, NewRowIndex, Column},
            NewCell = #cell{id = NewCellId, row = NewRowIndex, column = Column, value = ''},
%%            io:format("NewCell ~p\n", [NewCell]),
            mnesia:write(NewCell)
          end,
          lists:seq(1, NumColumns))
        end,
      mnesia:transaction(F),
      %% Aggiorna l'elenco delle celle nel tab con i nuovi id delle celle per la nuova riga
      NewCellIds = lists:foldl(
        fun(Column, Acc) ->
          [{TabName, NewRowIndex, Column} | Acc]
        end,
        [],
        lists:seq(1, NumColumns)),
%%      io:format("NewCellIds ~p\n", [NewCellIds]),
      NewTab = #tab{name = TabName, cells_ids = CellIds ++ lists:reverse(NewCellIds)},
%%      io:format("NewTab ~p\n", [NewTab]),
      case mnesia:transaction(fun() -> mnesia:write(NewTab) end) of
        {atomic,_Val} -> ok;
        {aborted, Reason} -> {error, Reason}
      end;
    [] ->
      {error, tab_not_found}
  end.


del_row(NameSheet, Tab, Index) ->
  %% Trova il numero di colonne nel tab
  TabName = lists:concat([atom_to_list(NameSheet), integer_to_list(Tab)]),
  case mnesia:dirty_read(tab, TabName) of
    [{tab, _, CellIds}] ->
      delete_cell(CellIds,Index),
      refresh_tabs_ids(CellIds,Index,TabName);
    [] ->
      {error, tab_not_found}
  end.

delete_cell(CellIds, Index) ->
  %% Filtra solo le celle che corrispondono alla riga specificata
  CellIdsFiltered = lists:filter(
    fun({_, RowIndex, _}) ->
      RowIndex == Index
    end,
    CellIds),
  %% Elimina completamente le righe dal database
  F = fun() ->
    lists:foreach(
      fun(IdsFilter) ->
%%        io:format("IdsFilter ~p\n", [IdsFilter]),
        %% Rimuovi l'elemento anche dall'elenco delle celle del tab
        mnesia:delete({cell, IdsFilter})
      end,
      CellIdsFiltered)
      end,
  mnesia:transaction(F)
.

refresh_tabs_ids(CellIds,Index,TabName) ->
  CellIdsFiltered = lists:filter(
    fun({_, RowIndex, _}) ->
      RowIndex /= Index
    end,
    CellIds),
%%  io:format("CellIdsFiltered ~p\n", [CellIdsFiltered]),
  NewTab = #tab{name = TabName, cells_ids = CellIdsFiltered},
  mnesia:dirty_write(NewTab),
  ok .