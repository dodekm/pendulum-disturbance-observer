function root = project_root
%PROJECT_ROOT Locate the canonical project without relying on current folder.
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
end
