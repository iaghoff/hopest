/*
  This file is part of hopest.
  hopest is a Fortran/C library and application for high-order mesh
  preprocessing and interfacing to the p4est apaptive mesh library.

  Copyright (C) 2014 by the developers.

  hopest is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  hopest is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with hopest; if not, write to the Free Software Foundation, Inc.,
  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
*/

#ifndef _HOPEST_P4EST_HO_GEOMETRY_H
#define _HOPEST_P4EST_HO_GEOMETRY_H

#include <hopest.h>
#include <p8est_geometry.h>

void p4_geometry_X (p8est_geometry_t * geom,
                                           p4est_topidx_t which_tree,
                                           const double abc[3],
                                           double xyz[3]);


#define buildHOp4GeometryX_FC \
  HOPEST_FC_FUNC (wrapbuildhop4geometryx,WRAPBUILDHOP4ESTGEOMETRY)

#ifdef __cplusplus
extern              "C"         /* prevent C++ name mangling */
{
#if 0
}
#endif
#endif

void buildHOp4GeometryX_FC(double,double,double,double*,double*,double*,p4est_topidx_t);

#ifdef __cplusplus
#if 0
{
#endif
}
#endif

#endif /* _HOPEST_P4EST_HO_GEOMETRY_H */
