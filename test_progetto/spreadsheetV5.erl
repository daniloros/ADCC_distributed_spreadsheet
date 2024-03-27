-module(spreadsheetV5).
-author("daniros").


-record(cell, {id, row, column, value={primitive, undef}}).
-record(sheet_page, {name, cells_ids=[]}).
-record(sheet, {name, sheet_page_ids=[]}).


%% API
-export([init/0, start/0, populate_cell/3, create_sheet/4]).


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

create_sheet(Name, NumSheetName, NumRows, NumColumns) ->
  {atomic, CellIds} = mnesia:transaction(fun() -> populate_cell(NumSheetName, NumRows, NumColumns) end),
%%  io:format("CellIds ~p\n", [CellIds]),
  F = fun() ->
    populate_sheet_page(Name, NumSheetName, CellIds),
    SheetNameRef = lists:seq(1,NumSheetName),
    Sheet = #sheet{name = Name, sheet_page_ids = SheetNameRef},
    mnesia:write(Sheet)
      end,
  {atomic, Val} = mnesia:transaction(F),
  Val
.

populate_cell(NumSheetName, NumRows, NumColumns) ->
  Rows = lists:seq(1, NumRows),
  Columns = lists:seq(1, NumColumns),
  SheetNumber = lists:seq(1,NumSheetName),
  CellIds = lists:foldl(
    fun(Sheet, Acc) ->
      SheetCellIds = lists:foldl(
        fun(Row, AccRows) ->
          RowCellIds = lists:foldl(
            fun(Column, AccColumns) ->
              Cell = #cell{
                id = {Sheet, Row, Column},
                row = Row,
                column = Column,
                value = "A"
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
    [], SheetNumber),
  lists:reverse(CellIds)
.


populate_sheet_page(SheetName, NumberSheetPage, RefCell) ->
  Number = lists:seq(1, NumberSheetPage),
  lists:foreach(
    fun(K) ->
      PageName = lists:concat([atom_to_list(SheetName), integer_to_list(K)]),
      SheetPage = #sheet_page{name = PageName, cells_ids = RefCell},
      mnesia:write(SheetPage)
    end,
    Number)
.