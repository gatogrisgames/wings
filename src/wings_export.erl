%%
%%  wings_export.erl --
%%
%%     This module handles export to other file formats.
%%
%%  Copyright (c) 2004-2009 Bjorn Gustavsson
%%
%%  See the file "license.terms" for information on usage and redistribution
%%  of this file, and for a DISCLAIMER OF ALL WARRANTIES.
%%
%%     $Id$
%%

-module(wings_export).
-export([export/4,save_images/3,make_mesh/2]).

-include("wings.hrl").
-include("e3d.hrl").
-include("e3d_image.hrl").
-import(lists, [foldl/3,keydelete/3,reverse/1]).

export(Exporter, Name, Ps, #st{shapes=Shs}=St0) ->
    St = wings_view:freeze_mirror(St0),
    Objs = foldl(fun(W, A) ->
			 export_1(W, Ps, A)
		 end, [], gb_trees:values(Shs)),
    wings_pb:start(?__(1,"exporting")),
    wings_pb:update(0.01,?__(2,"preparing")),
    Creator = "Wings 3D " ++ ?WINGS_VERSION,

    Mat0 = wings_material:used_materials(St),
    Mat1 = keydelete('_hole_', 1, Mat0),
    Mat = mat_images(Mat1),
    Contents = #e3d_file{objs=Objs,mat=Mat,creator=Creator},
    wings_pb:update(1.0),
    try Exporter(Name, Contents) of
	ok -> ok;
	{error,Atom} when is_atom(Atom) ->
	    wings_u:error(file:format_error(Atom));
	{error,Reason} ->
	    wings_u:error(Reason)
    catch
	error:Reason ->
	    Msg = ?__(4,"Exporter crashed"),
	    wings_u:error(Msg++": ~P\n\n~P\n",
			  [Reason,20,erlang:get_stacktrace(),20])
    after
	wings_pb:done()
    end.

save_images(#e3d_file{mat=Mat0}=E3DFile, Dir, Filetype) ->
    Mat = save_images_1(Mat0, Dir, Filetype, []),
    E3DFile#e3d_file{mat=Mat}.

%%%
%%% Local functions.
%%%

export_1(#we{perm=Perm}, _, Acc) when ?IS_NOT_VISIBLE(Perm) -> Acc;
export_1(#we{name=Name}=We, Ps, Acc) when not ?IS_ANY_LIGHT(We) ->
    Mesh = make_mesh(We, Ps),
    [#e3d_object{name=Name,obj=Mesh}|Acc];
export_1(_, _, Acc) -> Acc.

make_mesh(We0, Ps) ->
    SubDivs = proplists:get_value(subdivisions, Ps, 0),
    Tess = proplists:get_value(tesselation, Ps, none),
    We1 = sub_divide(SubDivs, We0),
    We2 = tesselate(Tess, We1),
    #we{vp=Vs0,es=Etab,he=He0} = We = wings_we:renumber(We2, 0),
    Vs = array:sparse_to_list(Vs0),
    {ColTab0,UvTab0} = make_tables(Ps, We),
    ColTab1 = gb_trees:from_orddict(ColTab0),
    UvTab1 = gb_trees:from_orddict(UvTab0),
    Fs0 = foldl(fun({_,'_hole_'}, A) -> A;
		   ({Face,Mat}, A) ->
			case make_face(Face, Mat, ColTab1, UvTab1, We) of
			    #e3d_face{vs=[_,_]} -> A;
			    E3DFace -> [E3DFace|A]
			end
		end, [], wings_facemat:all(We)),
    Fs = reverse(Fs0),
    He = case proplists:get_value(include_hard_edges, Ps, true) of
	     false -> [];
	     true -> hard_edges(gb_sets:to_list(He0), Etab, [])
	 end,
    Matrix = e3d_mat:identity(),
    ColTab = strip_numbers(ColTab0),
    UvTab = strip_numbers(UvTab0),
    Mesh = #e3d_mesh{type=polygon,fs=Fs,vs=Vs,tx=UvTab,he=He,
		     vc=ColTab,matrix=Matrix},
    e3d_mesh:renumber(Mesh).

sub_divide(0, We) -> We;
sub_divide(N, We0) ->
    We = wings_subdiv:smooth(We0),
    sub_divide(N-1, We).

tesselate(none, We) -> We;
tesselate(triangulate,We) -> 
    wings_tesselation:triangulate(We);
tesselate(quadrangulate,We) ->
    wings_tesselation:quadrangulate(We).

make_face(Face, Mat, ColTab, UvTab, We) ->
    E3dFace0 = make_plain_face(Face, Mat, We),
    E3dFace = add_uvs(Face, E3dFace0, UvTab, We),
    add_colors(Face, E3dFace, ColTab, We).

make_plain_face(Face, Mat, We) ->
    Vs = wings_face:vertices_ccw(Face, We),
    #e3d_face{vs=Vs,mat=make_face_mat(Mat)}.

add_uvs(Face, #e3d_face{vs=Vs}=E3dFace, UvTab, We) ->
    case gb_trees:is_empty(UvTab) of
	true -> E3dFace;
	false ->
	    UVs0 = wings_va:face_attr(uv, Face, We),
	    UVs1 = [gb_trees:get(UV, UvTab) || {_,_}=UV <- UVs0],
	    UVs = if
		      length(Vs) =:= length(UVs1) -> UVs1;
		      true -> []
		  end,
	    E3dFace#e3d_face{tx=UVs}
    end.

add_colors(Face, E3dFace, ColTab, We) ->
    case gb_trees:is_empty(ColTab) of
	true -> E3dFace;
	false ->
	    Cols0 = wings_va:face_attr(color, Face, We),
	    Cols = [gb_trees:get(def_color(C), ColTab) || C <- Cols0],
	    E3dFace#e3d_face{vc=Cols}
    end.

def_color({_,_,_}=C) -> C;
def_color(_) -> {1.0,1.0,1.0}.

make_tables(Ps, We) ->
    {case proplists:get_value(include_colors, Ps, true) of
	 false ->
	     [];
	 true ->
	     ColorTable0 = wings_va:all(color, We),
	     case ColorTable0 of
		 [] -> [];
		 [_|_] ->
		     ColorTable = ordsets:add_element(wings_color:white(),
						      ColorTable0),
		     number(ColorTable)
	     end
     end,
     case proplists:get_value(include_uvs, Ps, true) of
	 false -> [];
	 true -> number(wings_va:all(uv, We))
     end}.

number(L) ->
    number(L, 0, []).

number([H|T], I, Acc) ->
    number(T, I+1, [{H,I}|Acc]);
number([], _, Acc) -> reverse(Acc).

strip_numbers(L) ->
    strip_numbers(L, []).
strip_numbers([{H,_}|T], Acc) ->
    strip_numbers(T, [H|Acc]);
strip_numbers([], Acc) -> reverse(Acc).

make_face_mat([_|_]=Mat) -> Mat;
make_face_mat(Mat) -> [Mat].

hard_edges([E|Es], Etab, Acc) ->
    #edge{vs=Va,ve=Vb} = array:get(E, Etab),
    hard_edges(Es, Etab, [hard(Va, Vb)|Acc]);
hard_edges([], _Etab, Acc) -> Acc.

hard(A, B) when A < B -> {A,B};
hard(A, B) -> {B,A}.

mat_images(Mats) ->
    mat_images(Mats, []).

mat_images([{Name,Mat0}|T], Acc) ->
    Mat = mat_images_1(Mat0, []),
    mat_images(T, [{Name,Mat}|Acc]);
mat_images([], Acc) -> Acc.

mat_images_1([{maps,Maps0}|T], Acc) ->
    Maps = mat_images_2(Maps0, []),
    mat_images_1(T, [{maps,Maps}|Acc]);
mat_images_1([H|T], Acc) ->
    mat_images_1(T, [H|Acc]);
mat_images_1([], Acc) -> Acc.

mat_images_2([{Type,Id}|T], Acc) ->
    Im = wings_image:info(Id),
    mat_images_2(T, [{Type,Im}|Acc]);
mat_images_2([], Acc) -> Acc.

%%% Save all images.

save_images_1([{Name,Mat0}|T], Dir, Filetype, Acc) ->
    Mat = save_images_2(Mat0, Dir, Filetype, []),
    save_images_1(T, Dir, Filetype, [{Name,Mat}|Acc]);
save_images_1([], _, _, Acc) -> Acc.

save_images_2([{maps,Maps0}|T], Dir, Filetype, Acc) ->
    Maps = save_images_3(Maps0, Dir, Filetype, []),
    save_images_2(T, Dir, Filetype, [{maps,Maps}|Acc]);
save_images_2([H|T], Dir, Filetype, Acc) ->
    save_images_2(T, Dir, Filetype, [H|Acc]);
save_images_2([], _, _, Acc) -> Acc.

save_images_3([{Type,#e3d_image{filename=none,name=Name}=Im0}|T],
	      Dir, Filetype, Acc) ->
    Filename = filename:absname(Name ++ Filetype, Dir),
    Im = Im0#e3d_image{filename=Filename},
    Ps = [{filename,Filename},{image,Im}],
    wings_image:image_write(Ps),
    save_images_3(T, Dir, Filetype, [{Type,Im}|Acc]);
save_images_3([H|T], Dir, Filetype, Acc) ->
    save_images_3(T, Dir, Filetype, [H|Acc]);
save_images_3([], _, _, Acc) -> Acc.
