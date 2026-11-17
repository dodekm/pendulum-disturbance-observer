function receipt=write_checkpoint(target,tempPath,checkpointResult)
%WRITE_CHECKPOINT Background-only MAT-v7 snapshot and same-directory commit.
clock=tic;
save(tempPath,'checkpointResult','-v7','-nocompression');
[ok,msg]=movefile(tempPath,target,'f');
if ~ok,error('pendulumlab:Checkpoint','Checkpoint commit failed: %s',msg);end
receipt=struct('sample',checkpointResult.metadata.checkpoint_sample,'io_seconds',toc(clock));
end
