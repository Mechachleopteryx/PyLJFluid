/*  Copyright (C) 2012 Matt Hagy <hagy@gatech.edu>
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

#ifndef _LJ_FORCES_H_
#define _LJ_FORCES_H_

void
PyLJFluid_evaluate_LJ_forces(double *forces,
                             size_t N_neighbors,
                             unsigned int* neighbors,
                             double *positions,
                             double box_size,
                             double sigma, double epsilon, double r_cutoff);

#endif /* _LJ_FORCES_H_ */
