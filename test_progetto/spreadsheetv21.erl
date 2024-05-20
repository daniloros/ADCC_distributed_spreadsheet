-module(spreadsheetv21).
-author("daniros").


-record(cell, {id, row, column, value}).
-record(sheet_page, {name, cells_ids=[]}).
-record(sheet, {name, sheet_page_ids=[], owner_pid, access_policies=[]}).



%% API
-export([init/0, start/0, populate_cell/4, new/1, new/4, share/2, set/5, get/4, get/5, set/6,
  to_csv/1, to_csv/2, from_cvs/1, from_cvs/2, info/1]).


init() ->
  mnesia:create_schema([node()|nodes()]),
  mnesia:start(),
  create_tables(),
  mnesia:stop()
.

create_tables() ->
  mnesia:create_table(cell, [{attributes, record_info(fields, cell)}]),
  mnesia:create_table(sheet_page, [{attributes, record_info(fields, sheet_page)}]),
  mnesia:create_table(sheet, [{attributes, record_info(fields, sheet)}])
.

start() ->
  mnesia:start(),
  mnesia:wait_for_tables([sheet,sheet_page,cell], 20000)
.


new(Name) ->
  new(Name, 6, 3, 1)
.
%%%-------------------------------------------------------------------
%%% L'idea è avere una struttura fatta in questo modo:
%%% #sheet:
%%%   #sheet_page (TAB):
%%%     #celle
%%%  #sheet_page (TAB):
%%%     #celle

%%% Quindi come prima cosa creo le celle. Ogni cella dovrà avere un id differente
%%%   e questo id lo userò come riferimento per collegarlo ai Tab
%%% Ogni tab quindi conterrà il riferimento alle celle e dovrà avere un id univoco,
%%%   l'id lo userò come riferimento per collegarlo al foglio
%%% Infine creo il foglio con il suo nome e conterrà il riferimento ai sui tab
%%%-------------------------------------------------------------------
new(Name, N, M, K) ->
%%  io:format("entrato \n"),
%%  io:format("entrato - Name: ~p\n", [Name]),
  case sheet_alredy_exists(Name) of
    {atomic,true} ->
      {error, 'sheet already exists'};
    {atomic,false} ->
      try
        {atomic, CellIds} = mnesia:transaction(fun() -> populate_cell(Name, K, N, M) end),
        %%  io:format("CellIds ~p\n", [CellIds]),
        F = fun() ->
          populate_sheet_page(Name, K, CellIds),
          SheetPageRef = lists:seq(1,K),
          Sheet = #sheet{name = Name, sheet_page_ids = SheetPageRef, owner_pid = node()},
          mnesia:write(Sheet)
            end,
        {atomic, Val} = mnesia:transaction(F),
        {ok, Val}
      catch
        _:Reason -> {error, Reason}
      end
  end
.

populate_cell(NameSheet, NumSheetPage, NumRows, NumColumns) ->
  Rows = lists:seq(1, NumRows),
  Columns = lists:seq(1, NumColumns),
  SheetPageNumber = lists:seq(1,NumSheetPage),
  CellIds = lists:foldl(
    fun(Sheet, Acc) ->
      PageName = lists:concat([atom_to_list(NameSheet), integer_to_list(Sheet)]),
      SheetCellIds = lists:foldl(
        fun(Row, AccRows) ->
          RowCellIds = lists:foldl(
            fun(Column, AccColumns) ->
              Cell = #cell{
                id = {PageName, Row, Column},
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
    [], SheetPageNumber),
  lists:reverse(CellIds)
.


populate_sheet_page(SheetPageNumber, NumberSheetPage, RefCell) ->
%%  io:format("RefCell ~p\n", [RefCell]),
  Number = lists:seq(1, NumberSheetPage),
  lists:foreach(
    fun(K) ->
      PageName = lists:concat([atom_to_list(SheetPageNumber), integer_to_list(K)]),
      %% filtro poichè devo inserire solo le celle che riferiscono al TAB di interessa
      %% altrimenti ogni tab avrebbe il riferimento a tutte le celle anche di altre tab
      PageCellIds = lists:filter(
        fun(Cell) ->
          case Cell of
            %% se inizia con il PageName che mi interessa allora true
            {PageName, _, _} -> true;
            _ -> false
          end
        end,
        RefCell),
%%      io:format("RefCell ~p\n", [PageCellIds]),
      SheetPage = #sheet_page{name = PageName, cells_ids = PageCellIds},
%%      io:format("SheetPage ~p\n", [SheetPage]),
      mnesia:write(SheetPage)
    end,
    Number)
.

sheet_alredy_exists(Name) ->
%%  io:format("check if exist \n"),
  F = fun() ->
    case mnesia:dirty_read({sheet, Name}) of
      [] ->
%%        io:format("vuoto\n"),
        false;
      _  ->
%%        io:format("esiste \n"),
        true
    end
      end,
  mnesia:transaction(F)
.

get_sheet(SpreadsheetName) ->
  mnesia:dirty_read({sheet, SpreadsheetName})
.

share(SpreadsheetName, AccessPolicies) ->
  Node = node(),
  io:format("self ~p\n", [Node]),
  F = fun() ->
    case mnesia:read({sheet, SpreadsheetName}) of
      %% torna una lista di sheet
      [Sheet] ->
        io:format("Sheet ~p\n ", [Sheet]),
        %% controllo se chi chiama l'operazione è l'admin del foglio
        case Sheet#sheet.owner_pid =:= Node of
          true ->
            NewAccessPolicies = update_access_policies(Sheet#sheet.access_policies, AccessPolicies),
            io:format("NewAccessPolicies ~p\n ", [NewAccessPolicies]),
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
  io:format("Transaction result: ~p\n", [TransactionResult]),
  TransactionResult
.

update_access_policies(OldPolicies, NewPolicies) ->
  lists:foldl(
    fun({NewProc, NewAP}, Acc) ->
      io:format("Acc ~p\n", [Acc]),
      io:format("NewProc ~p\n", [NewProc]),

      case lists:keymember(NewProc, 1, OldPolicies) of
        true ->
          io:format("Replace ~p\n", [NewProc]),
          % If the process already has a policy, update it
          lists:keyreplace(NewProc, 1, Acc, {NewProc, NewAP});
        false ->
          io:format("Add new ~p\n", [NewProc]),
          % If the process doesn't have a policy, add it
          [{NewProc, NewAP} | Acc]
      end
    end,
    OldPolicies,
    NewPolicies
  )
.

check_policy_access(NameSpreadsheet, Process) ->
  case mnesia:dirty_read({sheet, NameSpreadsheet}) of
    [Sheet] ->
      AccessPolicies = Sheet#sheet.access_policies,
      Owner = Sheet#sheet.owner_pid,
      case Owner =:= Process of
        true ->
%%          io:format("Sei l'owner, hai tutti i diritti \n"),
          {true,true};
        false ->
%%          io:format("Risultato ~p\n", [lists:keyfind(Process, 1, AccessPolicies)]),
          lists:keyfind(Process, 1, AccessPolicies)
      end;
    [] -> not_found
  end
.

get(Name, Tab, Row, Column) ->
  Node = node(),
%%  io:format("SELF ~p\n", [Self]),
  case check_policy_access(Name, Node) of
    {_, _} ->
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
%% TODO: Vedere per il timeout l'abort amnesia
get(Name, Tab, Row, Column,Timeout) ->
%%  io:format("timeout ~p\n", [Timeout]),
  Self = self(),
  Node = node(),
%%  io:format("SELF ~p\n", [Self]),
  case check_policy_access(Name, Node) of
    {_, _} ->
      PageName = lists:concat([atom_to_list(Name), integer_to_list(Tab)]),
      Caller = spawn(fun() -> do_get(PageName, Row, Column, Self) end),
%%      io:format("Spawned process: ~p\n", [_Pid]),
      receive
        {result, Result} ->
%%          io:format("Value is: ~p\n", [Result]),
          {ok, Result};
        {error, not_found} -> {error, not_found}
      after Timeout ->
%%        io:format("Timeout waiting for response\n"),
        exit(Caller, kill),
        {error, timeout}
      end;
    not_found -> io:format("ERROR - spreadsheet non esistente\n"),
      {error, not_found};
    false -> io:format("ERROR - Non hai i diritti per accedere al file\n"),
      {error, no_access}
  end
.

do_get(PageName, Row, Column, Ref) ->
  timer:sleep(2000),
  case mnesia:dirty_read(cell, {PageName, Row, Column}) of
    [Cell] ->
      Result = Cell#cell.value,
%%      io:format("do_get, Result: ~p\n", [Result]),
      Ref ! {result, Result}; % Invia il risultato al processo chiamante
    [] ->
%%      io:format("do_get, Cell not found\n"),
      Ref ! {error, not_found} % Invia un messaggio di "non trovato"
  end
.


set(Name,Tab,Row,Column, Value) ->
  Node = node(),
  PageName = lists:concat([atom_to_list(Name), integer_to_list(Tab)]),
  case check_policy_access(Name, Node) of
    {_,write} ->
      F = fun() ->
        case mnesia:read(cell, {PageName,Row,Column}) of
          [Cell] ->
            UpdateCell = Cell#cell{value = Value},
            mnesia:write(UpdateCell);
          [] -> {error, not_found}
        end
          end,

      case mnesia:transaction(F) of
        {atomic, Val} -> {ok,Val};
        {aborted, _Reason} -> {error, not_found}
      end;
    {_,true} ->
      F = fun() ->
        case mnesia:read(cell, {PageName,Row,Column}) of
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
%% TODO: Vedere per il timeout l'abort amnesia
set(Name,Tab,Row,Column, Value, Timeout) ->
  Self = self(),
  Node = node(),
  PageName = lists:concat([atom_to_list(Name), integer_to_list(Tab)]),
  case check_policy_access(Name, Node) of
    {_,write} ->
      Caller = spawn(fun() -> do_set(PageName, Row, Column, Value, Self) end),
      receive_response(Caller, Timeout);
    {_,true} ->
%%      io:format("true case\n"),
      Caller = spawn(fun() -> do_set(PageName, Row, Column, Value, Self) end),
      receive_response(Caller, Timeout);
    {_,read} -> io:format("Puoi solo leggere il file\n");
    {_,_} -> {error, wrong_policies};
    not_found -> io:format("ERROR - spreadsheet non esistente\n");
    false -> io:format("ERROR - Non hai i diritti per accedere al file\n")
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


do_set(PageName, Row, Column, Value, Ref) ->
  timer:sleep(2000),
  F = fun() ->
    [Cell] = mnesia:read(cell, {PageName,Row,Column}),
    io:format("Cell ~p\n", [Cell]),
    UpdateCell = Cell#cell{value = Value},
    mnesia:write(UpdateCell)
      end,
  Result = mnesia:transaction(F),
  io:format("Result ~p\n", [Result]),
  case Result of
    {atomic, ok} -> Ref!{ok, true};
    {atomic, {error, not_found}} -> Ref!{error, not_found};
      {aborted, _Reason} -> Ref!{error, error}
  end
.

get_all_cell_values(SpreadsheetName) ->
  case get_sheet(SpreadsheetName) of
    [Sheet] ->
      SheetPages = Sheet#sheet.sheet_page_ids,
      [get_cell_values(SpreadsheetName, Page) || Page <- SheetPages];
    _ ->
      {error, not_found}
  end.

get_cell_values(SpreadsheetName, PageName) ->
  NewPageName = lists:concat([atom_to_list(SpreadsheetName), integer_to_list(PageName)]),
  case mnesia:dirty_read(sheet_page, NewPageName) of
    [{sheet_page, _, CellIds}] ->
%%      io:format("CellIds ~p\n", [CellIds]),

      %% prendo le righe per ogni cellIds %%
      RowNumbers = [Row || {_, Row, _} <- CellIds],
%%      io:format("RowsNumbers ~p\n", [RowNumbers]),

      %% elimino i duplicati %%
      Rows = lists:usort(RowNumbers),

%%      io:format("Rows ~p\n", [Rows]),
      [get_row_values(NewPageName, Row) || Row <- Rows];
    _ ->
      []
  end.

get_row_values(SpreadsheetName, Rows) ->
%%  io:format("PageName ~p\n", [PageName]),
%%  io:format("Row ~p\n", [Rows]),

  %% faccio la query per cercare tutte le righe %%
  RowCells = mnesia:dirty_match_object({cell, {SpreadsheetName, Rows, '_'}, '_', '_', '_'}),
%%  io:format("RowCells ~p\n", [RowCells]),

  %% costretto ad ordinare RowCells, altrimenti il dirty_match_object non torna dati ordinati %%%
  %% devo confrontare in base all'indice della colonna %%
  SortedCells = lists:sort(fun(A, B) -> A#cell.column < B#cell.column end, RowCells),
%%  io:format("SortedCells ~p\n", [SortedCells]),
  [Value || #cell{value = Value} <- SortedCells].


to_csv(SpreadsheetName) ->
  do_to_cvs(SpreadsheetName, null)
.


to_csv(SpreadsheetName, Timeout) ->
  Parent = self(),
  Caller = spawn(fun() -> do_to_cvs(SpreadsheetName, Parent) end),
  receive
    {csv_data, Data} -> {ok, Data}
  after Timeout ->
    exit(Caller, kill),
    {error, timeout}
  end
.

do_to_cvs(SpreadsheetName, Parent) ->
  case Parent of
    null ->
      case get_all_cell_values(SpreadsheetName) of
        [Data] ->
          io:format("Data ~p\n", [Data]),
          CsvRows = lists:map(
            fun(Row) ->
%%            io:format("Row ~p\n", [Row]),
              %% per ogni row converto in intero le concateno separate da virgole e a fine riga vado a capo %%
              RowStrings = [case X of
                              %% Se X è un numero, lo converto in stringa
                              Num when is_number(Num) -> integer_to_list(Num);
                              %% Se X è una stringa, lo lascio invariato
                              Str when is_list(Str) -> Str;
                              %% Se X è un atomo
                              Atom when is_atom(Atom) -> atom_to_list(Atom)
                            end || X <- Row],
              CsvRow = string:join(RowStrings, ",") ++ "\n",
%%            io:format("CSVRow ~p\n", [CsvRow]),
              CsvRow
            end,
            Data),

          %% "appiattisco" le stringhe per scriverle nel .csv, passaggio necessario per il write_file %%
          CsvContent = lists:flatten(CsvRows),
%%      io:format("CSVContent ~p", [CsvContent]),
          StringSpreadsheetName = atom_to_list(SpreadsheetName),
          FilePath = StringSpreadsheetName ++ ".csv",
          file:write_file(FilePath, CsvContent),
          {ok, FilePath};
        {error, Reason} ->
          {error, Reason}
      end;
    _ -> case get_all_cell_values(SpreadsheetName) of
           [Data] ->
%%             io:format("Data ~p\n", [Data]),
%%             timer:sleep(2000),
             CsvRows = lists:map(
               fun(Row) ->
%%            io:format("Row ~p\n", [Row]),
                 %% per ogni row converto in intero le concateno separate da virgole e a fine riga vado a capo %%
                 RowStrings = [case X of
                                 %% Se X è un numero, lo converto in stringa
                                 Num when is_number(Num) -> integer_to_list(Num);
                                 %% Se X è una stringa, lo lascio invariato
                                 Str when is_list(Str) -> Str;
                                 %% Se X è un atomo
                                 Atom when is_atom(Atom) -> atom_to_list(Atom)
                               end || X <- Row],
                 CsvRow = string:join(RowStrings, ",") ++ "\n",
%%            io:format("CSVRow ~p\n", [CsvRow]),
                 CsvRow
               end,
               Data),

             %% "appiattisco" le stringhe per scriverle nel .csv, passaggio necessario per il write_file %%
             CsvContent = lists:flatten(CsvRows),
%%      io:format("CSVContent ~p", [CsvContent]),
             StringSpreadsheetName = atom_to_list(SpreadsheetName),
             FilePath = StringSpreadsheetName ++ ".csv",
             file:write_file(FilePath, CsvContent),
             Parent ! {csv_data, FilePath};
           {error, Reason} ->
             {error, Reason}
         end
  end
.

from_cvs(FilePath) ->
  do_from_cvs(FilePath,null)
.

from_cvs(FilePath, Timeout) ->
  Parent = self(),
  Caller = spawn(fun() -> do_from_cvs(FilePath, Parent) end),
  receive
    {csv_data, Data} -> {ok, Data}
  after Timeout ->
    exit(Caller, kill),
    {error, timeout}
  end
.

do_from_cvs(FilePath, Parent) ->
  case Parent of
    null ->
      {ok, File} = file:open(FilePath, [read]),
      BaseName = filename:basename(FilePath),
      NameWithoutExtension = list_to_atom(string:substr(BaseName, 1, string:rstr(BaseName, ".") - 1)),
      io:format("BaseName ~p\n",[BaseName]),
      io:format("NameWithoutExtension ~p\n",[NameWithoutExtension]),
      CsvData = read_lines(File, []),
      {RowCount, ColumnCount} = get_row_column_count(CsvData),
      io:format("Count Row ~p\n", [RowCount]),
      io:format("Count Column ~p\n", [ColumnCount]),
      case new(NameWithoutExtension, RowCount, ColumnCount, 1) of
        {error, 'sheet already exists'} -> io:format("Foglio già esistente, cambiare il nome \n");
        _ ->
          RowCounter = lists:seq(1,RowCount),
          ColumnCounter = lists:seq(1, ColumnCount),
          lists:foreach(
            fun(RowIndex) ->
              Row = lists:nth(RowIndex, CsvData),
              io:format("Row: ~p\n", [Row]),
              lists:foreach(
                fun(ColumnIndex) ->
                  ValueString = lists:nth(ColumnIndex, Row),
%%              io:format("Value is: ~p\n", [ValueString]),
                  CleanValue = string:strip(ValueString, right, $\n),
%%              io:format("OK - CleanValue is: ~p\n", [CleanValue]),
                  set(NameWithoutExtension, 1, RowIndex, ColumnIndex, CleanValue)
                end,
                ColumnCounter)
            end,
            RowCounter),
          ok
        %%  {CsvData, RowCount, ColumnCount}
      end;
    _ ->
      timer:sleep(2000),
      {ok, File} = file:open(FilePath, [read]),
      BaseName = filename:basename(FilePath),
      NameWithoutExtension = list_to_atom(string:substr(BaseName, 1, string:rstr(BaseName, ".") - 1)),
      io:format("BaseName ~p\n",[BaseName]),
      io:format("NameWithoutExtension ~p\n",[NameWithoutExtension]),
      CsvData = read_lines(File, []),
      {RowCount, ColumnCount} = get_row_column_count(CsvData),
      io:format("Count Row ~p\n", [RowCount]),
      io:format("Count Column ~p\n", [ColumnCount]),
      case new(NameWithoutExtension, RowCount, ColumnCount, 1) of
        {error, 'sheet already exists'} -> io:format("somaro \n");
        _ ->
          RowCounter = lists:seq(1,RowCount),
          ColumnCounter = lists:seq(1, ColumnCount),
          lists:foreach(
            fun(RowIndex) ->
              Row = lists:nth(RowIndex, CsvData),
              io:format("Row: ~p\n", [Row]),
              lists:foreach(
                fun(ColumnIndex) ->
                  ValueString = lists:nth(ColumnIndex, Row),
%%              io:format("Value is: ~p\n", [ValueString]),
                  CleanValue = string:strip(ValueString, right, $\n),
%%              io:format("OK - CleanValue is: ~p\n", [CleanValue]),
                  set(NameWithoutExtension, 1, RowIndex, ColumnIndex, CleanValue)
                end,
                ColumnCounter)
            end,
            RowCounter),
          Parent ! {ok, ok}
      end
  end
.


read_lines(File, Acc) ->
  case file:read_line(File) of
    {ok, Line} ->
      Tokens = string:tokens(Line, ","),
      read_lines(File, [Tokens | Acc]);
    eof ->
      file:close(File),
      lists:reverse(Acc);
    {error, Reason} ->
      file:close(File),
      {error, Reason}
  end.


get_row_column_count(CsvData) ->
  RowCount = length(CsvData),
  ColumnCount = lists:max(lists:map(fun(L) -> length(L) end, CsvData)),
  {RowCount, ColumnCount}.


info(Name) ->
  Process = node(),
  io:format("self ~p\n", [Process]),
  case get_sheet(Name) of
    [Sheet] ->
      AccessPolicies = Sheet#sheet.access_policies,
      io:format("Permessi: ~p\n", [AccessPolicies]),
      TabCellCounts = lists:map(fun(Tab) ->
        PageName = lists:concat([atom_to_list(Name), integer_to_list(Tab)]),
        case mnesia:dirty_read(sheet_page, PageName) of
          [{sheet_page, _, CellIds}] ->
            {Tab, length(CellIds)};
          _ ->
            {Tab, 0}
        end
                                end, Sheet#sheet.sheet_page_ids),
      io:format("numero di celle per tab: ~p\n", [TabCellCounts]);
    _ ->
      {error, not_found}
  end
.


%%% ok timeout per cvs, aggiungere case per open:file perchè se è il file non esiste ritorna:
%%% {badmatch,{error,enoent}

