-module(spreadsheetv17).
-author("daniros").


-record(cell, {id, row, column, value}).
-record(sheet_page, {name, cells_ids=[]}).
-record(sheet, {name, sheet_page_ids=[], owner_pid, access_policies=[]}).



%% API
-export([init/0, start/0, populate_cell/4, new/1, new/4, share/2, get_sheet/1,
  set/5, get/4, sheet_alredy_exists/1,
  get_all_cell_values/1, to_csv/1, from_cvs/1, get_row_column_count/1]).


init() ->
  mnesia:create_schema([node()]),
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
  io:format("entrato \n"),
  io:format("entrato - Name: ~p\n", [Name]),
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
          Sheet = #sheet{name = Name, sheet_page_ids = SheetPageRef, owner_pid = self()},
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
  io:format("check if exist \n"),
  F = fun() ->
    case mnesia:dirty_read({sheet, Name}) of
      [] ->
        io:format("vuoto\n"),
        false;
      _  ->
        io:format("esiste \n"),
        true
    end
      end,
  mnesia:transaction(F)
.

get_sheet(SpreadsheetName) ->
  mnesia:dirty_read({sheet, SpreadsheetName})
.

share(SpreadsheetName, AccessPolicies) ->
  Self = self(),
  F = fun() ->
        case mnesia:dirty_read({sheet, SpreadsheetName}) of
          %% torna una lista di sheet
          [Sheet] ->
            io:format("Sheet ~p\n ", [Sheet]),
            %% controllo se chi chiama l'operazione è l'admin del foglio
            case Sheet#sheet.owner_pid =:= Self of
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
  mnesia:transaction(F)
.

update_access_policies(OldPolicies, NewPolicies) ->
  lists:foldl(
    fun({NewProc, NewAP}, Acc) ->
      io:format("Acc ~p\n", [Acc]),
      io:format("NewProc ~p\n", [NewProc]),

      case lists:keymember(NewProc, 1, OldPolicies) of
        true ->
          % If the process already has a policy, update it
          lists:keyreplace(NewProc, 1, Acc, {NewProc, NewAP});
        false ->
          % If the process doesn't have a policy, add it
          [{NewProc, NewAP} | Acc]
      end
    end,
    OldPolicies,
    NewPolicies
  )
.



%% TODO: Da aggiungere controllo errori
get(Name,Tab,Row,Column) ->
  Timeout = 5000,
  Self = self(),
  PageName = lists:concat([atom_to_list(Name), integer_to_list(Tab)]),
  _Pid = spawn(fun() -> do_get(PageName, Row, Column, Self) end),
  receive
    {result, Result} -> ok, io:format("Value is: ~p\n",[Result]);
    {error, not_found} -> {error, not_found}
  after Timeout -> {error, timeout}
  end
.

do_get(PageName, Row, Column, Ref) ->
  case mnesia:dirty_read(cell, {PageName, Row, Column}) of
    [Cell] ->
      Result = Cell#cell.value,
      Ref!{result, Result}; % Invia il risultato al processo chiamante
    [] ->
      Ref ! {error, not_found} % Invia un messaggio di "non trovato"
  end.


%%% TODO: Da Aggiungere controllo errori
set(Name,Tab,Row,Column, Value) ->
  Timeout = 1000,
  Self = self(),
  PageName = lists:concat([atom_to_list(Name), integer_to_list(Tab)]),
  TimerRef = erlang:send_after(Timeout, self(), timeout),
  _Pid = spawn(fun() -> do_set(PageName, Row, Column, Value, Self, TimerRef) end),
  receive
    {ok, Val} -> Val;
    {error, not_found} -> {error, not_found};
    {error, timeout} -> {error, timeout}
  after Timeout -> {error, timeout}
  end
.

do_set(PageName, Row, Column, Value, Ref, TimerRef) ->
  timer:sleep(3000),
  F = fun() ->
    [Cell] = mnesia:read(cell, {PageName,Row,Column}),
    UpdateCell = Cell#cell{value = Value},
    mnesia:write(UpdateCell)
      end,
  case mnesia:transaction(F) of
    {atomic, Val} ->
      Ref!{ok,Val},
      erlang:cancel_timer(TimerRef);
    {aborted, _Reason} ->
      Ref!{error, not_found},
      erlang:cancel_timer(TimerRef)
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
  case get_all_cell_values(SpreadsheetName) of
    [Data] ->
      io:format("Data ~p\n", [Data]),
      CsvRows = lists:map(
        fun(Row) ->
%%            io:format("Row ~p\n", [Row]),
          %% per ogni row converto in intero le concateno separate da virgole e a fine riga vado a capo %%
          RowStrings = [integer_to_list(X) || X <- Row],
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
  end.


from_cvs(FilePath) ->
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
      ok
  end
%%  {CsvData, RowCount, ColumnCount}
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


%%% FUNZIONE SHARE SEMBRA OK > DA FARE TEST

%%% COSE RIMANENTI:
%%% ORA CHE LO SHARE FUNZIONA, AGGIUNGERE I CONTROLLI SULLE OPERAZIONI AD ESEMPIO
%%% GET POSSO FARLA SE HO I DIRITTI DI LETTURA O SCRITTURA
%%% SET SOLO SE HO I DIRITTI DI SCRITTURA

%%% CAPIRE SE PER I TIMEOUT POSSO USARE ABORT DI MNESIA (VEDI DOCUMENTAZIONE)

%%% ANCORA DA IMPLEMENTARE LA FUNZIONE INFO

